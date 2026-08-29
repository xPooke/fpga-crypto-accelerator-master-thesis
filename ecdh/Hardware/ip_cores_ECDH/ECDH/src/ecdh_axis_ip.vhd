----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ecdh_axis_ip
-- Project Name  : ECDH accelerator over GF(2^571) (master thesis)
-- Module Name   : ecdh_axis_ip - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : AXI-Stream wrapper of the ECDH core (sha3_axis_ip pattern).
--                 Ties three parts together: ecdh_deserializer (packet
--                 cmd||Qx||Qy -> operands), the k*P core (-> affine),
--                 ecdh_serializer ((x,y) -> stream). The private scalar k does
--                 NOT travel through the stream but side-band (i_k + strobe
--                 i_k_valid), so it never passes through software/PS.
--                 Result: KEYGEN -> m_axis (public), SHARED -> m_axis_z
--                 (secret, straight to SHA3). Figure: figures/ecdh_axis_ip.svg.
--
--                 The compute core is selected at elaboration by the boolean
--                 generic G_LOW_LATENCY (an if-generate; only the chosen branch
--                 is synthesized, no area cost for the other):
--                   * true  -> ecdh_core_low_latency  (Phase-2, minimum latency: parallel
--                              Montgomery step, three multipliers; larger area)
--                   * false -> ecdh_core_basic     (Phase-1, baseline: single shared
--                              gf_alu, smaller area, higher latency)
--                 Both cores are drop-in (identical generics/ports) and produce
--                 the bit-identical result; only area/latency differ. The AXIS
--                 glue and packet protocol are independent of the choice.
--
-- Dependencies  : work.ecdh_deserializer, work.ecdh_serializer,
--                 work.ecdh_core_low_latency (G_LOW_LATENCY=true),
--                 work.ecdh_core_basic    (G_LOW_LATENCY=false)
--
-- Revision      :
--   0.01 - August 2026 - File Created
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). One operation in flight:
--   while the core computes, the deserializer accepts no new packet
--   (i_ready=0). Core start = deserializer o_valid AND r_k_loaded (k must be
--   loaded by its strobe first; a packet arriving earlier waits in S_WAIT_K).
--   Command: cmd(0)='1' -> SHARED, otherwise KEYGEN. bitlen(k) timing leak:
--   see SPEC_ec_scalar_mult.md.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity ecdh_axis_ip is
    generic (
        G_M           : integer := 4;
        G_D           : integer := 1;
        G_F           : std_logic_vector := "10011";  -- f WITH the leading bit (G_M+1 bits)
        G_B           : std_logic_vector := "0001";   -- curve parameter b (G_M bits)
        DATA_WIDTH    : integer := 8;                 -- 8, 16, 32, 64
        G_LOW_LATENCY : boolean := true               -- true=ecdh_core_low_latency (fast), false=ecdh_core_basic (small)
    );
    port (
        i_clk    : in  std_logic;
        i_resetn : in  std_logic;                            -- active low

        -- private scalar k (side-band, strobe i_k_valid — AES i_key/i_key_valid pattern)
        i_k       : in  std_logic_vector(G_M-1 downto 0);
        i_k_valid : in  std_logic;

        -- AXI-Stream slave: operand packet (cmd || Qx || Qy)
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tlast  : in  std_logic;

        -- AXI-Stream master: PUBLIC result (KEYGEN: Qa = x || y)
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tlast  : out std_logic;

        -- AXI-Stream master: SECRET x(S) (SHARED) -> straight to SHA3, never the PS
        m_axis_z_tvalid : out std_logic;
        m_axis_z_tready : in  std_logic;
        m_axis_z_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_z_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_z_tlast  : out std_logic
    );
end entity;


architecture rtl of ecdh_axis_ip is

    -- position copy normalizes an unconstrained generic's (0 to m-1) range
    -- (slicing G_B directly would break for an ascending-range actual)
    constant c_B : std_logic_vector(G_M-1 downto 0) := G_B;

    ----------------------------------------------------------------------------
    -- Wrapper orchestration FSM
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_WAIT_K, S_CORE, S_SER);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Datapath registers
    ----------------------------------------------------------------------------
    -- k side-band latch (kept across KEYGEN and SHARED — the same k)
    signal r_k        : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal r_k_loaded : std_logic := '0';

    -- command snapshot (cmd(0): 1=SHARED, 0=KEYGEN)
    signal r_shared : std_logic := '0';

    ----------------------------------------------------------------------------
    -- Instance wiring
    ----------------------------------------------------------------------------
    -- deserializer
    signal w_des_cmd   : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_des_qx    : std_logic_vector(G_M-1 downto 0);
    signal w_des_qy    : std_logic_vector(G_M-1 downto 0);
    signal w_des_valid : std_logic;
    signal w_des_ready : std_logic;

    -- ecdh_top
    signal w_core_start             : std_logic;
    signal w_core_busy, w_core_done : std_logic;
    signal w_core_x, w_core_y       : std_logic_vector(G_M-1 downto 0);

    -- serializer
    signal w_ser_start            : std_logic;
    signal w_ser_busy, w_ser_done : std_logic;

begin

    assert G_F'length = G_M + 1
        report "G_F must be the irreducible polynomial WITH its leading bit (G_M+1 bits)"
        severity failure;

    assert G_B'length = G_M
        report "G_B is a field element (curve parameter b) and must be exactly G_M bits"
        severity failure;

    assert DATA_WIDTH mod 8 = 0
        report "DATA_WIDTH must be a whole number of bytes (TKEEP is DATA_WIDTH/8 wide)"
        severity failure;

    ----------------------------------------------------------------------------
    -- k side-band latch: the i_k_valid strobe samples k; kept until reset
    ----------------------------------------------------------------------------
    p_KLATCH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_k        <= (others => '0');
                r_k_loaded <= '0';
            elsif i_k_valid = '1' then
                r_k        <= i_k;
                r_k_loaded <= '1';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Deserializer: accepts a packet only while the wrapper is in S_IDLE
    ----------------------------------------------------------------------------
    w_des_ready <= '1' when state_reg = S_IDLE else '0';

    u_des : entity work.ecdh_deserializer
        generic map (
            G_M        => G_M,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            i_clk         => i_clk,
            i_resetn      => i_resetn,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tlast  => s_axis_tlast,
            i_ready       => w_des_ready,
            o_cmd         => w_des_cmd,
            o_qx          => w_des_qx,
            o_qy          => w_des_qy,
            o_valid       => w_des_valid
        );

    ----------------------------------------------------------------------------
    -- Core: k*P -> affine (x,y). k from the side-band latch, P from the packet.
    ----------------------------------------------------------------------------
    w_core_start <= '1' when state_reg = S_CORE and w_core_busy = '0' else '0';

    -- Core selection at elaboration: only the chosen branch is instantiated and
    -- synthesized. Both cores share the exact same generics/ports, so the two
    -- branches differ only in the entity name.
    gen_low_latency : if G_LOW_LATENCY generate
        u_core : entity work.ecdh_core_low_latency           -- Phase 2: minimum latency
            generic map (
                G_M => G_M,
                G_D => G_D,
                G_F => G_F
            )
            port map (
                i_clk    => i_clk,
                i_resetn => i_resetn,
                i_start  => w_core_start,
                i_k      => r_k,
                i_xb     => w_des_qx,
                i_yb     => w_des_qy,
                i_b      => c_B,
                o_x      => w_core_x,
                o_y      => w_core_y,
                o_busy   => w_core_busy,
                o_done   => w_core_done
            );
    else generate
        u_core : entity work.ecdh_core_basic              -- Phase 1: baseline (small area)
            generic map (
                G_M => G_M,
                G_D => G_D,
                G_F => G_F
            )
            port map (
                i_clk    => i_clk,
                i_resetn => i_resetn,
                i_start  => w_core_start,
                i_k      => r_k,
                i_xb     => w_des_qx,
                i_yb     => w_des_qy,
                i_b      => c_B,
                o_x      => w_core_x,
                o_y      => w_core_y,
                o_busy   => w_core_busy,
                o_done   => w_core_done
            );
    end generate;

    ----------------------------------------------------------------------------
    -- Serializer: (x,y) -> stream; the command picks m_axis (KEYGEN) /
    -- m_axis_z (SHARED)
    ----------------------------------------------------------------------------
    w_ser_start <= '1' when state_reg = S_SER and w_ser_busy = '0' else '0';

    u_ser : entity work.ecdh_serializer
        generic map (
            G_M        => G_M,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            i_clk           => i_clk,
            i_resetn        => i_resetn,
            i_start         => w_ser_start,
            i_shared        => r_shared,
            i_x             => w_core_x,
            i_y             => w_core_y,
            o_busy          => w_ser_busy,
            o_done          => w_ser_done,
            m_axis_tvalid   => m_axis_tvalid,
            m_axis_tready   => m_axis_tready,
            m_axis_tdata    => m_axis_tdata,
            m_axis_tkeep    => m_axis_tkeep,
            m_axis_tlast    => m_axis_tlast,
            m_axis_z_tvalid => m_axis_z_tvalid,
            m_axis_z_tready => m_axis_z_tready,
            m_axis_z_tdata  => m_axis_z_tdata,
            m_axis_z_tkeep  => m_axis_z_tkeep,
            m_axis_z_tlast  => m_axis_z_tlast
        );

    ----------------------------------------------------------------------------
    -- FSM state register
    ----------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                state_reg <= S_IDLE;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM next state (combinational)
    --   S_IDLE   : wait for a complete packet (deserializer o_valid)
    --   S_WAIT_K : packet ready but k not loaded yet -> wait for the strobe
    --   S_CORE   : the core computes k*P
    --   S_SER    : the serializer sends the result
    ----------------------------------------------------------------------------
    p_NEXT_STATE : process(all)
    begin
        next_state <= state_reg;

        case state_reg is
            when S_IDLE =>
                if w_des_valid = '1' then
                    if r_k_loaded = '1' then
                        next_state <= S_CORE;
                    else
                        next_state <= S_WAIT_K;
                    end if;
                end if;
            when S_WAIT_K =>
                if r_k_loaded = '1' then
                    next_state <= S_CORE;
                end if;
            when S_CORE =>
                if w_core_done = '1' then
                    next_state <= S_SER;
                end if;
            when S_SER =>
                if w_ser_done = '1' then
                    next_state <= S_IDLE;
                end if;
        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Command snapshot on packet completion (deserializer outputs are stable
    -- from o_valid onward)
    ----------------------------------------------------------------------------
    p_CMD : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_shared <= '0';
            elsif state_reg = S_IDLE and w_des_valid = '1' then
                r_shared <= w_des_cmd(0);   -- cmd(0)=1 -> SHARED, 0 -> KEYGEN
            end if;
        end if;
    end process;

end architecture;
