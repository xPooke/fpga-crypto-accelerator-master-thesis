----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ecdh_serializer
-- Module Name   : ecdh_serializer - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Parallel (x,y) -> AXI-Stream master. On i_start packs the
--                 result into words (LSB word first) and sends it on one of
--                 the two master interfaces, selected by the command:
--                   KEYGEN (i_shared=0): x || y  -> m_axis      (public key)
--                   SHARED (i_shared=1): x       -> m_axis_z    (secret x(S))
--                 The other output stays silent (tvalid=0). Part of the
--                 ecdh_axis_ip wrapper.
--
-- Dependencies  : (none)
--
-- Revision      :
--   0.01 - August 2026 - File Created
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). Output TKEEP = all ones (the
--   result is always a whole number of words; the upper partial word is
--   zero-padded). Backpressure: a word is held stable until the active tready
--   arrives. o_done is a 1-clock pulse when the last word is accepted.
--   Keeping the secret separate (SHARED -> only m_axis_z, the public m_axis
--   silent) is a security property (thesis §4.5).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity ecdh_serializer is
    generic (
        G_M        : integer := 4;
        DATA_WIDTH : integer := 8
    );
    port (
        i_clk    : in  std_logic;
        i_resetn : in  std_logic;
        i_start  : in  std_logic;                         -- pulse: begin sending
        i_shared : in  std_logic;                         -- 0=KEYGEN(x,y), 1=SHARED(x)
        i_x      : in  std_logic_vector(G_M-1 downto 0);
        i_y      : in  std_logic_vector(G_M-1 downto 0);
        o_busy   : out std_logic;
        o_done   : out std_logic;                         -- pulse: packet sent
        -- AXI-Stream master: public result (KEYGEN)
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tlast  : out std_logic;
        -- AXI-Stream master: secret x(S) (SHARED) -> straight to SHA3
        m_axis_z_tvalid : out std_logic;
        m_axis_z_tready : in  std_logic;
        m_axis_z_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_z_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_z_tlast  : out std_logic
    );
end entity;


architecture rtl of ecdh_serializer is

    constant c_N     : integer := (G_M + DATA_WIDTH - 1) / DATA_WIDTH;
                       -- words per field: ceil(4/8) = 1
    constant c_ZWORD : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');

    type state_t is (S_IDLE, S_SEND);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Datapath registers
    ----------------------------------------------------------------------------
    -- output shift register: lower N words = x, upper N words = y
    signal r_out    : std_logic_vector(2*c_N*DATA_WIDTH-1 downto 0) := (others => '0');
    signal r_shared : std_logic := '0';
    signal r_cnt    : integer range 0 to 2*c_N := 0;   -- words sent

    ----------------------------------------------------------------------------
    -- Combinational helpers
    ----------------------------------------------------------------------------
    signal w_nwords : integer range 1 to 2*c_N;        -- total words to send
    signal w_tready : std_logic;                       -- active tready (by command)
    signal w_last   : std_logic;                       -- last word

begin

    -- Shared combinational helpers
    w_nwords <= c_N when r_shared = '1' else 2*c_N;
    w_tready <= m_axis_z_tready when r_shared = '1' else m_axis_tready;
    w_last   <= '1' when r_cnt = w_nwords - 1 else '0';

    ----------------------------------------------------------------------------
    -- Combinational, master side: the data fan out to both buses, the command
    -- selects which tvalid speaks — the inactive output stays silent
    ----------------------------------------------------------------------------
    p_COMB_MASTER : process(all)
    begin
        m_axis_tdata    <= r_out(DATA_WIDTH-1 downto 0);
        m_axis_z_tdata  <= r_out(DATA_WIDTH-1 downto 0);
        m_axis_tkeep    <= (others => '1');
        m_axis_z_tkeep  <= (others => '1');
        m_axis_tvalid   <= '0';
        m_axis_z_tvalid <= '0';
        m_axis_tlast    <= '0';
        m_axis_z_tlast  <= '0';

        if state_reg = S_SEND then
            if r_shared = '1' then
                m_axis_z_tvalid <= '1';
                m_axis_z_tlast  <= w_last;
            else
                m_axis_tvalid <= '1';
                m_axis_tlast  <= w_last;
            end if;
        end if;
    end process;

    o_busy <= '1' when state_reg = S_SEND else '0';
    o_done <= '1' when (state_reg = S_SEND and w_tready = '1' and w_last = '1') else '0';

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
    ----------------------------------------------------------------------------
    p_NEXT_STATE : process(all)
    begin
        next_state <= state_reg;

        case state_reg is
            when S_IDLE =>
                if i_start = '1' then
                    next_state <= S_SEND;
                end if;
            when S_SEND =>
                if w_tready = '1' and w_last = '1' then
                    next_state <= S_IDLE;
                end if;
        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Datapath: load r_out on i_start, shift per accepted word
    -- (loading through a variable — more reliable than slice-override on a
    -- signal)
    ----------------------------------------------------------------------------
    p_DATAPATH : process(i_clk)
        variable v_out : std_logic_vector(2*c_N*DATA_WIDTH-1 downto 0);
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_out    <= (others => '0');
                r_shared <= '0';
                r_cnt    <= 0;
            else
                case state_reg is

                    when S_IDLE =>
                        if i_start = '1' then
                            r_shared <= i_shared;
                            r_cnt    <= 0;
                            v_out := (others => '0');
                            v_out(G_M-1 downto 0) := i_x;                  -- x into the lower N words
                            if i_shared = '0' then                         -- KEYGEN: y into the upper N too
                                v_out(c_N*DATA_WIDTH + G_M-1 downto c_N*DATA_WIDTH) := i_y;
                            end if;
                            r_out <= v_out;
                        end if;

                    when S_SEND =>
                        if w_tready = '1' then
                            -- shift right by one word (the sent lower word drops out)
                            r_out <= c_ZWORD & r_out(2*c_N*DATA_WIDTH-1 downto DATA_WIDTH);
                            if w_last = '0' then
                                r_cnt <= r_cnt + 1;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture;
