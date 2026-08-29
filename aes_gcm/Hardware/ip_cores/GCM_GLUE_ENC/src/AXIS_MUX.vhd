--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : axis_mux
-- Module Name   : axis_mux - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : 3-to-1 AXIS multiplexer for the GCM encrypt output.
--                 Selects one of three inbound streams (s_aad, s_ct, s_icv)
--                 as the outbound m_axis stream and advances through them
--                 in fixed order:
--                   S_AAD  -> S_CT   after AAD_BEATS handshakes
--                   S_CT   -> S_ICV  on the TLAST of the CT stream
--                   S_ICV  -> restart after the ICV beat handshake
--                 When AAD_BEATS = 0 the FSM starts directly in S_CT (the
--                 AAD phase is skipped entirely). Output m_axis_tlast is
--                 asserted only on the ICV beat (end of the full
--                 encrypted packet).
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 Active-low reset.
--                 aad_last() returns 0 instead of (AAD_BEATS-1) when
--                 AAD_BEATS=0 to avoid an illegal NATURAL argument to
--                 to_unsigned at elaboration; the value is unused at run
--                 time because S_AAD is never entered in that case.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_mux is
    generic (
        AAD_BEATS  : natural  := 2;
        DATA_WIDTH : positive := 128
    );
    port (
        i_clk          : in  std_logic;
        i_rstn         : in  std_logic;

        s_aad_tdata    : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_aad_tkeep    : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_aad_tvalid   : in  std_logic;
        s_aad_tready   : out std_logic;

        s_ct_tdata     : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_ct_tkeep     : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_ct_tvalid    : in  std_logic;
        s_ct_tlast     : in  std_logic;
        s_ct_tready    : out std_logic;

        s_icv_tdata    : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_icv_tkeep    : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_icv_tvalid   : in  std_logic;
        s_icv_tready   : out std_logic;

        m_axis_tdata   : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep   : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid  : out std_logic;
        m_axis_tlast   : out std_logic;
        m_axis_tready  : in  std_logic
    );
end entity;

architecture rtl of axis_mux is

    type state_t is (S_AAD, S_CT, S_ICV);
    signal state_reg     : state_t;
    signal next_state    : state_t;
    signal r_aad_cnt     : unsigned(7 downto 0) := (others => '0');
    signal w_master_handshake : std_logic;

    -- Initial state depends on whether AAD is present
    function initial_state(aad : natural) return state_t is
    begin
        if aad > 0 then
            return S_AAD;
        else
            return S_CT;
        end if;
    end function;

    -- "Last AAD index" used in the S_AAD beat-count compare.
    -- When AAD_BEATS=0 this returns 0 instead of computing AAD_BEATS-1 (= -1),
    -- which would be an illegal NATURAL argument to to_unsigned and fail at
    -- elaboration (the expression is checked even though S_AAD is never entered
    -- when AAD_BEATS=0, since initial_state returns S_CT). The value is unused
    -- at run time; it only needs to be a legal constant.
    function aad_last(aad : natural) return natural is
    begin
        if aad = 0 then
            return 0;
        else
            return aad - 1;
        end if;
    end function;

    constant c_AAD_LAST : natural := aad_last(AAD_BEATS);

    signal w_master_tvalid: std_logic;
begin

    w_master_handshake <= w_master_tvalid and m_axis_tready;

    ----------------------------------------------------------------
    -- FSM state register (sequential)
    ----------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                state_reg <= initial_state(AAD_BEATS);
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- FSM next-state logic (combinational)
    ----------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, w_master_handshake, r_aad_cnt, s_ct_tlast)
    begin
        next_state <= state_reg;
        case state_reg is
            when S_AAD =>
                if w_master_handshake = '1' and
                   r_aad_cnt = to_unsigned(c_AAD_LAST, r_aad_cnt'length) then
                    next_state <= S_CT;
                end if;
            when S_CT =>
                if w_master_handshake = '1' and s_ct_tlast = '1' then
                    next_state <= S_ICV;
                end if;
            when S_ICV =>
                if w_master_handshake = '1' then
                    next_state <= initial_state(AAD_BEATS);
                end if;
        end case;
    end process;

    ----------------------------------------------------------------
    -- AAD beat counter
    ----------------------------------------------------------------
    p_AAD_CNT : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_aad_cnt <= (others => '0');
            elsif state_reg = S_AAD and w_master_handshake = '1' then
                if r_aad_cnt = to_unsigned(c_AAD_LAST, r_aad_cnt'length) then
                    r_aad_cnt <= (others => '0');
                else
                    r_aad_cnt <= r_aad_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- Master output: select based on state
    ----------------------------------------------------------------
    m_axis_tdata <= s_aad_tdata when state_reg = S_AAD else
                    s_ct_tdata  when state_reg = S_CT  else
                    s_icv_tdata;

    m_axis_tkeep <= s_aad_tkeep when state_reg = S_AAD else
                    s_ct_tkeep  when state_reg = S_CT  else
                    s_icv_tkeep;

    w_master_tvalid <= s_aad_tvalid when state_reg = S_AAD else
                     s_ct_tvalid  when state_reg = S_CT  else
                     s_icv_tvalid;
    m_axis_tvalid <= w_master_tvalid;
    -- TLAST is high only on the ICV beat (end of full output packet)
    m_axis_tlast <= s_icv_tvalid when state_reg = S_ICV else '0';

    ----------------------------------------------------------------
    -- Slave tready: only the active slave receives master tready
    ----------------------------------------------------------------
    s_aad_tready <= m_axis_tready when state_reg = S_AAD else '0';
    s_ct_tready  <= m_axis_tready when state_reg = S_CT  else '0';
    s_icv_tready <= m_axis_tready when state_reg = S_ICV else '0';

end architecture;
