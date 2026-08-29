--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : Jun 2026
-- Design Name   : AXIS_skid_buffer
-- Module Name   : AXIS_skid_buffer - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : Two-deep AXIS register slice with skid storage.
--                 Adds 1 cycle of latency between upstream master and
--                 downstream slave while sustaining 1 beat/cycle in
--                 steady state. Preserves all beats when the downstream
--                 de-asserts TREADY.
--
--                 Internally holds two registers:
--                   r_main : drives m_axis (visible to downstream)
--                   r_skid : 1-deep skid storage used when downstream
--                            stalls while upstream still has a valid
--                            beat on the wire
--
--                 FSM:
--                   S_EMPTY - both registers empty; accept upstream
--                   S_ONE   - r_main holds a beat; accept upstream
--                             (will push to skid if downstream stalls)
--                   S_TWO   - both r_main and r_skid hold a beat;
--                             upstream is back-pressured (s_tready=0)
--
--                 Carries TDATA, TVALID, TLAST, TREADY only. TKEEP and
--                 TUSER are deliberately omitted.
-- Dependencies  : ieee.std_logic_1164
-- Revision      : 0.01 - Jun 2026 - File created
-- Additional Comments :
--                 Active-low reset (i_rstn). Single clock domain
--                 (i_clk). Data registers (r_main_data/r_skid_data)
--                 deliberately not reset — their values are don't-care
--                 when TVALID=0 and skipping the reset saves placement
--                 effort on the 128-bit data path. Only the FSM state
--                 is reset.
--
--                 Generic DATA_WIDTH defaults to 128 (GCM block size);
--                 module is data-width agnostic and reusable.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity AXIS_skid_buffer is
    generic (
        DATA_WIDTH : positive := 128
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;

        -- AXIS slave (upstream side)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXIS master (downstream side)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity;

architecture rtl of AXIS_skid_buffer is

    type state_t is (S_EMPTY, S_ONE, S_TWO);
    signal state_reg  : state_t := S_EMPTY;
    signal next_state : state_t := S_EMPTY;

    -- Main pipeline register: what the downstream sees on m_axis
    signal r_main_data : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal r_main_last : std_logic := '0';

    -- Skid storage: holds the beat accepted while downstream was stalled
    signal r_skid_data : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal r_skid_last : std_logic := '0';

begin

    --------------------------------------------------------------------------
    -- FSM state register
    --------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                state_reg <= S_EMPTY;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM next-state logic
    --------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, s_axis_tvalid, m_axis_tready)
    begin
        next_state <= state_reg;
        case state_reg is

            when S_EMPTY =>
                -- Accept incoming beat into r_main, advance to ONE
                if s_axis_tvalid = '1' then
                    next_state <= S_ONE;
                end if;

            when S_ONE =>
                if s_axis_tvalid = '1' and m_axis_tready = '0' then
                    -- Downstream stalled, upstream has new beat — push to skid
                    next_state <= S_TWO;
                elsif s_axis_tvalid = '0' and m_axis_tready = '1' then
                    -- Main consumed, nothing new — go empty
                    next_state <= S_EMPTY;
                end if;
                -- Other cases keep state (consume+accept, or pure hold)

            when S_TWO =>
                -- Drain skid into main when downstream resumes
                if m_axis_tready = '1' then
                    next_state <= S_ONE;
                end if;

        end case;
    end process;

    --------------------------------------------------------------------------
    -- Data path: update r_main / r_skid based on the CURRENT state and
    -- the handshake signals (clock-enabled FFs, no reset on data).
    --------------------------------------------------------------------------
    p_DATA : process(i_clk)
    begin
        if rising_edge(i_clk) then
            case state_reg is

                when S_EMPTY =>
                    if s_axis_tvalid = '1' then
                        r_main_data <= s_axis_tdata;
                        r_main_last <= s_axis_tlast;
                    end if;

                when S_ONE =>
                    if m_axis_tready = '1' and s_axis_tvalid = '1' then
                        -- Consume main, accept new beat into main
                        r_main_data <= s_axis_tdata;
                        r_main_last <= s_axis_tlast;
                    elsif m_axis_tready = '0' and s_axis_tvalid = '1' then
                        -- Main holds; capture upstream into skid
                        r_skid_data <= s_axis_tdata;
                        r_skid_last <= s_axis_tlast;
                    end if;
                    -- Other cases hold r_main / r_skid

                when S_TWO =>
                    if m_axis_tready = '1' then
                        -- Promote skid to main; skid effectively drained next cycle
                        r_main_data <= r_skid_data;
                        r_main_last <= r_skid_last;
                    end if;

            end case;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Output drivers (combinational, derived from state and registers)
    --------------------------------------------------------------------------
    s_axis_tready <= '1' when state_reg /= S_TWO  else '0';
    m_axis_tvalid <= '1' when state_reg /= S_EMPTY else '0';

    m_axis_tdata  <= r_main_data;
    m_axis_tlast  <= r_main_last;

end architecture;
