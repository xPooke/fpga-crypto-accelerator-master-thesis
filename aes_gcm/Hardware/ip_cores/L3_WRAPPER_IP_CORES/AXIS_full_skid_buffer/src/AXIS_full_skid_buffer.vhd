----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : AXIS_full_skid_buffer
-- Module Name   : AXIS_full_skid_buffer - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Full AXI-Stream skid buffer (TDATA / TKEEP / TLAST).
--
--                 Breaks the combinational path from m_axis_tready back to
--                 s_axis_tready: the slave ready comes straight out of the state
--                 register, so a slow downstream can no longer pull its timing
--                 into the upstream logic. It costs one cycle of latency and
--                 still sustains one beat per clock at full rate.
--
--                 The skid register holds the beat that was accepted in the
--                 cycle the downstream stalled - without it, that beat would
--                 have to be dropped or the ready path would have to be
--                 combinational.
--
-- Dependencies  : ieee.std_logic_1164
--
-- Revision      :
--   0.01 - June 2026 - File Created
--
-- Additional Comments :
--   Active-low reset (i_rstn). Only the state register is reset; the data
--   registers are plain clock-enabled FFs, which is what keeps them in
--   SRL/LUT-RAM friendly form.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;


entity AXIS_full_skid_buffer is
    generic (
        DATA_WIDTH : positive := 128
    );
    port (
        i_clk  : in  std_logic;
        i_rstn : in  std_logic;

        -- AXIS slave (upstream side)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXIS master (downstream side)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity;


architecture rtl of AXIS_full_skid_buffer is

    ----------------------------------------------------------------------------
    -- FSM
    --   S_EMPTY : nothing held
    --   S_ONE   : r_main holds the beat the downstream sees
    --   S_TWO   : r_main is stalled and r_skid holds the beat behind it
    ----------------------------------------------------------------------------
    type state_t is (S_EMPTY, S_ONE, S_TWO);
    signal state_reg, next_state : state_t := S_EMPTY;

    -- Main pipeline register: what the downstream sees on m_axis
    signal r_main_data  : std_logic_vector(DATA_WIDTH-1 downto 0)   := (others => '0');
    signal r_main_tkeep : std_logic_vector(DATA_WIDTH/8-1 downto 0) := (others => '0');
    signal r_main_last  : std_logic := '0';

    -- Skid storage: holds the beat accepted while the downstream was stalled
    signal r_skid_data  : std_logic_vector(DATA_WIDTH-1 downto 0)   := (others => '0');
    signal r_skid_tkeep : std_logic_vector(DATA_WIDTH/8-1 downto 0) := (others => '0');
    signal r_skid_last  : std_logic := '0';

begin

    --------------------------------------------------------------------------
    -- Slave side: ready is a pure function of the state register, which is what
    -- keeps m_axis_tready out of the upstream timing path.
    --------------------------------------------------------------------------
    p_SLAVE_IN : process(state_reg)
    begin
        if state_reg = S_TWO then
            s_axis_tready <= '0';   -- both registers full
        else
            s_axis_tready <= '1';
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Master side
    --------------------------------------------------------------------------
    p_MASTER_OUT : process(state_reg, r_main_data, r_main_tkeep, r_main_last)
    begin
        m_axis_tdata <= r_main_data;
        m_axis_tkeep <= r_main_tkeep;
        m_axis_tlast <= r_main_last;

        if state_reg = S_EMPTY then
            m_axis_tvalid <= '0';
        else
            m_axis_tvalid <= '1';
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Data path: update r_main / r_skid from the current state and the
    -- handshakes (clock-enabled FFs, no reset on the data).
    --------------------------------------------------------------------------
    p_DATA : process(i_clk)
    begin
        if rising_edge(i_clk) then
            case state_reg is

                when S_EMPTY =>
                    if s_axis_tvalid = '1' then
                        r_main_data  <= s_axis_tdata;
                        r_main_tkeep <= s_axis_tkeep;
                        r_main_last  <= s_axis_tlast;
                    end if;

                when S_ONE =>
                    if m_axis_tready = '1' and s_axis_tvalid = '1' then
                        -- Consume main, accept the new beat straight into main
                        r_main_data  <= s_axis_tdata;
                        r_main_tkeep <= s_axis_tkeep;
                        r_main_last  <= s_axis_tlast;
                    elsif m_axis_tready = '0' and s_axis_tvalid = '1' then
                        -- Main holds; the beat behind it goes into the skid
                        r_skid_data  <= s_axis_tdata;
                        r_skid_tkeep <= s_axis_tkeep;
                        r_skid_last  <= s_axis_tlast;
                    end if;

                when S_TWO =>
                    if m_axis_tready = '1' then
                        -- Promote the skid into main; the skid drains
                        r_main_data  <= r_skid_data;
                        r_main_tkeep <= r_skid_tkeep;
                        r_main_last  <= r_skid_last;
                    end if;

            end case;
        end if;
    end process;

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
                if s_axis_tvalid = '1' then
                    next_state <= S_ONE;
                end if;

            when S_ONE =>
                if s_axis_tvalid = '1' and m_axis_tready = '0' then
                    -- Downstream stalled while a new beat arrived: skid it
                    next_state <= S_TWO;
                elsif s_axis_tvalid = '0' and m_axis_tready = '1' then
                    -- Main drained and nothing new arrived
                    next_state <= S_EMPTY;
                end if;

            when S_TWO =>
                if m_axis_tready = '1' then
                    next_state <= S_ONE;
                end if;

        end case;
    end process;

end architecture;
