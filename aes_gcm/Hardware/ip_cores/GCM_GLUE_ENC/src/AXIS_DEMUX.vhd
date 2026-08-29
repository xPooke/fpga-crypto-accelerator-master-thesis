--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : axis_demux
-- Module Name   : axis_demux - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : Splits the encrypt path's inbound AXIS stream into
--                 separate AAD and PT outbound streams (AAD = the first
--                 AAD_BEATS beats; PT = everything after, up to TLAST).
--                 Counts the PT payload length at run time (with proper
--                 handling of partial last beats via tkeep) and emits the
--                 AAD and PT/CT bit lengths plus a one-cycle o_len_valid
--                 pulse to GHASH_wrapper so it can build the length block
--                 for the final tag.
--                 Generated as a two-state FSM (S_AAD, S_PT) when
--                 AAD_BEATS > 0, or as a counter-only passthrough when
--                 AAD_BEATS = 0 (AAD master idle).
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
-- Revision      : 0.01 - May 2026 - File created
--                 0.02 - July 2026 - AAD_BYTES generic added; o_aad_bit_len is
--                 now derived from it instead of AAD_BEATS * DATA_WIDTH, since
--                 the AAD length need not be a multiple of the bus width.
-- Additional Comments :
--                 Active-low reset.
--                 o_aad_bit_len is constant (= AAD_BYTES * 8);
--                 GHASH_wrapper can latch it once. o_ct_bit_len uses the
--                 tkeep of the last beat to compute a correct bit count
--                 even for partial final beats.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_demux is
    generic (
        AAD_BEATS  : natural  := 2;
        AAD_BYTES  : natural  := 20;
        DATA_WIDTH : positive := 128
    );
    port (
        i_clk          : in  std_logic;
        i_rstn         : in  std_logic;

        -- AXIS slave: AAD || PT (TLAST on last PT beat)
        s_axis_tdata   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep   : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tvalid  : in  std_logic;
        s_axis_tlast   : in  std_logic;
        s_axis_tready  : out std_logic;

        -- AXIS master: AAD output
        m_aad_tdata    : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_aad_tkeep    : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_aad_tvalid   : out std_logic;
        m_aad_tready   : in  std_logic;

        -- AXIS master: PT output
        m_pt_tdata     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_pt_tkeep     : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_pt_tvalid    : out std_logic;
        m_pt_tlast     : out std_logic;
        m_pt_tready    : in  std_logic;

        -- Side-band: lengths to GHASH wrapper
        o_aad_bit_len  : out std_logic_vector(63 downto 0);
        o_ct_bit_len   : out std_logic_vector(63 downto 0);  -- PT bit length (= CT bit length in enc)
        o_len_valid    : out std_logic
    );
end entity;

architecture rtl of axis_demux is

    -- Constant: AAD bit length from generic
    constant c_AAD_BIT_LEN : std_logic_vector(63 downto 0) :=
        std_logic_vector(to_unsigned(AAD_BYTES * 8, 64));

    -- Number of valid BITS in a beat, from its tkeep (8 bits per kept byte).
    -- For a full beat this returns DATA_WIDTH, so full-block packets compute
    -- exactly as before; partial last beats now contribute their true length.
    function keep_bits(keep : std_logic_vector) return integer is
        variable v_n : integer := 0;
    begin
        for i in keep'range loop
            if keep(i) = '1' then
                v_n := v_n + 8;
            end if;
        end loop;
        return v_n;
    end function;

begin

    ----------------------------------------------------------------
    -- Case 1: AAD present (AAD_BEATS > 0)
    ----------------------------------------------------------------
    gen_with_aad : if AAD_BEATS > 0 generate

        type state_t is (S_AAD, S_PT);
        signal state_reg  : state_t := S_AAD;
        signal next_state : state_t := S_AAD;

        signal r_aad_cnt : unsigned(7 downto 0)  := (others => '0');
        signal r_pt_cnt  : unsigned(56 downto 0) := (others => '0');

        signal r_pt_bit_len : std_logic_vector(63 downto 0) := (others => '0');
        signal r_len_valid  : std_logic := '0';

        signal w_slave_tready    : std_logic;
        signal w_slave_handshake : std_logic;

    begin

        w_slave_handshake <= s_axis_tvalid and w_slave_tready;

        ------------------------------------------------------------
        -- FSM state register (sequential)
        ------------------------------------------------------------
        p_STATE_REG : process(i_clk)
        begin
            if rising_edge(i_clk) then
                if i_rstn = '0' then
                    state_reg <= S_AAD;
                else
                    state_reg <= next_state;
                end if;
            end if;
        end process;

        ------------------------------------------------------------
        -- FSM next-state logic (combinational)
        ------------------------------------------------------------
        p_NEXT_STATE : process(state_reg, w_slave_handshake, r_aad_cnt,
                               s_axis_tlast)
        begin
            next_state <= state_reg;
            case state_reg is
                when S_AAD =>
                    if w_slave_handshake = '1' and
                       r_aad_cnt = to_unsigned(AAD_BEATS - 1, r_aad_cnt'length) then
                        next_state <= S_PT;
                    end if;
                when S_PT =>
                    if w_slave_handshake = '1' and s_axis_tlast = '1' then
                        next_state <= S_AAD;
                    end if;
            end case;
        end process;

        ------------------------------------------------------------
        -- FSM data path: counters, length latch, len_valid pulse
        ------------------------------------------------------------
        p_FSM_DATA : process(i_clk)
        begin
            if rising_edge(i_clk) then
                if i_rstn = '0' then
                    r_aad_cnt    <= (others => '0');
                    r_pt_cnt     <= (others => '0');
                    r_pt_bit_len <= (others => '0');
                    r_len_valid  <= '0';
                else
                    -- Default: deassert len_valid pulse
                    r_len_valid <= '0';

                    case state_reg is
                        when S_AAD =>
                            if w_slave_handshake = '1' then
                                if r_aad_cnt = to_unsigned(AAD_BEATS - 1,
                                                           r_aad_cnt'length) then
                                    r_aad_cnt <= (others => '0');
                                else
                                    r_aad_cnt <= r_aad_cnt + 1;
                                end if;
                            end if;

                        when S_PT =>
                            if w_slave_handshake = '1' then
                                if s_axis_tlast = '1' then
                                    -- Last PT beat: finalize length info.
                                    r_pt_bit_len <= std_logic_vector(
                                          resize(r_pt_cnt & "0000000", 64)
                                        + to_unsigned(keep_bits(s_axis_tkeep), 64));
                                    r_len_valid <= '1';
                                    r_pt_cnt    <= (others => '0');
                                else
                                    r_pt_cnt <= r_pt_cnt + 1;
                                end if;
                            end if;
                    end case;
                end if;
            end if;
        end process;

        ------------------------------------------------------------
        -- Combinational routing
        ------------------------------------------------------------
        m_aad_tdata <= s_axis_tdata;
        m_aad_tkeep <= s_axis_tkeep;
        m_pt_tdata  <= s_axis_tdata;
        m_pt_tkeep  <= s_axis_tkeep;

        m_aad_tvalid <= s_axis_tvalid when state_reg = S_AAD else '0';
        m_pt_tvalid  <= s_axis_tvalid when state_reg = S_PT  else '0';
        m_pt_tlast   <= s_axis_tlast  when state_reg = S_PT  else '0';

        w_slave_tready <= m_aad_tready when state_reg = S_AAD else m_pt_tready;
        s_axis_tready  <= w_slave_tready;

        ------------------------------------------------------------
        -- Side-band length outputs
        ------------------------------------------------------------
        o_aad_bit_len <= c_AAD_BIT_LEN;
        o_ct_bit_len  <= r_pt_bit_len;
        o_len_valid   <= r_len_valid;

    end generate;

    ----------------------------------------------------------------
    -- Case 2: No AAD (AAD_BEATS = 0)
    ----------------------------------------------------------------
    gen_no_aad : if AAD_BEATS = 0 generate

        signal r_pt_cnt     : unsigned(56 downto 0) := (others => '0');
        signal r_pt_bit_len : std_logic_vector(63 downto 0) := (others => '0');
        signal r_len_valid  : std_logic := '0';

        signal w_slave_tready    : std_logic;
        signal w_slave_handshake : std_logic;

    begin

        w_slave_tready     <= m_pt_tready;
        w_slave_handshake  <= s_axis_tvalid and w_slave_tready;

        ------------------------------------------------------------
        -- PT beat counter (no FSM needed, just count handshakes)
        ------------------------------------------------------------
        p_COUNTER : process(i_clk)
        begin
            if rising_edge(i_clk) then
                if i_rstn = '0' then
                    r_pt_cnt     <= (others => '0');
                    r_pt_bit_len <= (others => '0');
                    r_len_valid  <= '0';
                else
                    r_len_valid <= '0';

                    if w_slave_handshake = '1' then
                        if s_axis_tlast = '1' then
                            r_pt_bit_len <= std_logic_vector(
                                  resize(r_pt_cnt & "0000000", 64)
                                + to_unsigned(keep_bits(s_axis_tkeep), 64));
                            r_len_valid  <= '1';
                            r_pt_cnt     <= (others => '0');
                        else
                            r_pt_cnt <= r_pt_cnt + 1;
                        end if;
                    end if;
                end if;
            end if;
        end process;

        ------------------------------------------------------------
        -- AAD master idle
        ------------------------------------------------------------
        m_aad_tdata  <= (others => '0');
        m_aad_tkeep  <= (others => '0');
        m_aad_tvalid <= '0';

        ------------------------------------------------------------
        -- PT master direct passthrough
        ------------------------------------------------------------
        m_pt_tdata    <= s_axis_tdata;
        m_pt_tkeep    <= s_axis_tkeep;
        m_pt_tvalid   <= s_axis_tvalid;
        m_pt_tlast    <= s_axis_tlast;
        s_axis_tready <= w_slave_tready;

        ------------------------------------------------------------
        -- Side-band length outputs
        ------------------------------------------------------------
        o_aad_bit_len <= (others => '0');  -- AAD_BEATS=0 → aad_bit_len=0
        o_ct_bit_len  <= r_pt_bit_len;
        o_len_valid   <= r_len_valid;

    end generate;

end architecture;
