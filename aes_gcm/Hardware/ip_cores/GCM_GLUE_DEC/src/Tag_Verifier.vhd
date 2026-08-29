--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : Tag_Verifier
-- Module Name   : Tag_Verifier - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : GCM authentication-tag verifier. Compares the received
--                 ICV (single AXIS beat) against the locally computed tag:
--                   tag = Y XOR E_K(J0)
--                 where Y is the final GHASH output from GHASH_wrapper
--                 (i_Y / i_Y_valid) and E_K(J0) is the GCM "encrypt
--                 counter zero" from AES (i_EJ0 / i_EJ0_valid). Y and ICV
--                 can arrive in any order across independent cycles;
--                 pending flags hold whichever input lands first. As soon
--                 as both are available — either already latched OR
--                 arriving live this cycle — the comparator fires and
--                 o_auth_valid pulses for one cycle alongside the verdict
--                 on o_auth_ok.
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 Active-low reset.
--                 E_K(J0) is expected to arrive before Y/ICV (AES-CTR
--                 produces it early in the packet); the compare always
--                 uses the registered r_EJ0.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Tag_Verifier is
    port (
        i_clk          : in  std_logic;
        i_rstn         : in  std_logic;

        -- Side-band: E_K(J0) from AES-CTR (latched on valid pulse)
        i_EJ0          : in  std_logic_vector(127 downto 0);
        i_EJ0_valid    : in  std_logic;

        -- Side-band: Y from GHASH wrapper
        i_Y            : in  std_logic_vector(127 downto 0);
        i_Y_valid      : in  std_logic;

        -- AXIS slave: ICV received beat
        s_axis_tdata   : in  std_logic_vector(127 downto 0);
        s_axis_tvalid  : in  std_logic;
        s_axis_tlast   : in  std_logic;
        s_axis_tready  : out std_logic;

        -- Result
        o_auth_ok      : out std_logic;
        o_auth_valid   : out std_logic
    );
end entity;

architecture rtl of Tag_Verifier is

    ------------------------------------------------------------------
    -- FSM states (2 states)
    ------------------------------------------------------------------
    type state_t is (S_WAIT, S_DONE);
    signal state_reg  : state_t := S_WAIT;
    signal next_state : state_t := S_WAIT;

    ------------------------------------------------------------------
    -- Latched values
    ------------------------------------------------------------------
    signal r_EJ0     : std_logic_vector(127 downto 0) := (others => '0');
    signal r_ICV_rx  : std_logic_vector(127 downto 0) := (others => '0');
    signal r_Y_latch : std_logic_vector(127 downto 0) := (others => '0');

    ------------------------------------------------------------------
    -- Pending flags - set when each input arrives, cleared after compare.
    -- These still exist so Y and ICV may arrive in ANY order across
    -- different cycles; the optimization only removes the extra cycle for
    -- the SECOND input by also looking at its live valid (see below).
    ------------------------------------------------------------------
    signal r_icv_pending : std_logic := '0';
    signal r_y_pending   : std_logic := '0';

    ------------------------------------------------------------------
    -- Auth result
    ------------------------------------------------------------------
    signal r_auth_ok  : std_logic := '0';
    signal r_auth_vld : std_logic := '0';

    ------------------------------------------------------------------
    -- Internal helpers
    ------------------------------------------------------------------
    signal w_slave_tready : std_logic;
    signal w_icv_handshake     : std_logic;

    -- "Available this cycle" = already latched (pending) OR arriving live now
    signal w_y_avail   : std_logic;
    signal w_icv_avail : std_logic;
    signal w_both_now  : std_logic;

    -- Compare operands: use live data on the arrival cycle, latched otherwise
    signal w_y_cmp   : std_logic_vector(127 downto 0);
    signal w_icv_cmp : std_logic_vector(127 downto 0);
    signal w_tag_calc : std_logic_vector(127 downto 0);
    signal w_match    : std_logic;

    constant c_ZERO_128 : std_logic_vector(127 downto 0) := (others => '0');

begin

    ----------------------------------------------------------------------------
    -- Latch E_K(J0) on valid pulse (held until new packet).
    -- NOTE: E_K(J0) is expected to be available before Y/ICV (computed by
    -- AES-CTR early); the compare uses the registered r_EJ0.
    ----------------------------------------------------------------------------
    p_EJ0_LATCH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_EJ0_valid = '1' then
                r_EJ0 <= i_EJ0;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- ICV slave ready: accept ICV only when no pending ICV
    ----------------------------------------------------------------------------
    w_slave_tready <= '1' when r_icv_pending = '0' else '0';
    s_axis_tready  <= w_slave_tready;

    w_icv_handshake <= s_axis_tvalid and w_slave_tready;

    ----------------------------------------------------------------------------
    -- ICV capture process - set pending flag on AXIS handshake
    ----------------------------------------------------------------------------
    p_ICV_LATCH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_icv_pending <= '0';
                r_ICV_rx      <= (others => '0');
            else
                if w_icv_handshake = '1' then
                    r_ICV_rx      <= s_axis_tdata;
                    r_icv_pending <= '1';
                end if;

                -- Clear when compare completes
                if state_reg = S_DONE then
                    r_icv_pending <= '0';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Y capture process - set pending flag on Y_valid pulse
    ----------------------------------------------------------------------------
    p_Y_LATCH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_y_pending <= '0';
                r_Y_latch   <= (others => '0');
            else
                if i_Y_valid = '1' then
                    r_Y_latch   <= i_Y;
                    r_y_pending <= '1';
                end if;

                if state_reg = S_DONE then
                    r_y_pending <= '0';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Availability and compare operands (combinational).
    --
    -- Each input is usable this cycle if it is already latched (pending) or
    -- arriving live this cycle. When pending, the data is in the latch
    -- register; when arriving live (and not yet pending), use the live port.
    -- This lets the FSM fire one cycle after the SECOND input instead of
    -- waiting an extra cycle for it to register into a pending flag.
    ----------------------------------------------------------------------------
    w_y_avail   <= r_y_pending   or i_Y_valid;
    w_icv_avail <= r_icv_pending or w_icv_handshake;
    w_both_now  <= w_y_avail and w_icv_avail;

    w_y_cmp   <= r_Y_latch when r_y_pending = '1' else i_Y;
    w_icv_cmp <= r_ICV_rx  when r_icv_pending = '1' else s_axis_tdata;

    w_tag_calc <= w_y_cmp xor r_EJ0;
    w_match    <= '1' when (w_tag_calc xor w_icv_cmp) = c_ZERO_128 else '0';

    ----------------------------------------------------------------------------
    -- FSM state register (sequential)
    ----------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                state_reg <= S_WAIT;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Auth output register: r_auth_vld is a 1-cycle pulse asserted on the
    -- S_WAIT -> S_DONE transition; r_auth_ok latches the compare result.
    ----------------------------------------------------------------------------
    p_AUTH_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_auth_ok  <= '0';
                r_auth_vld <= '0';
            else
                r_auth_vld <= '0';
                if state_reg = S_WAIT and next_state = S_DONE then
                    r_auth_ok  <= w_match;
                    r_auth_vld <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM next-state logic (combinational)
    ----------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, w_both_now)
    begin
        next_state <= state_reg;
        case state_reg is
            when S_WAIT =>
                -- Fire as soon as both inputs are available this cycle
                -- (latched or live), in any arrival order.
                if w_both_now = '1' then
                    next_state <= S_DONE;
                end if;

            when S_DONE =>
                -- One cycle: pending flags cleared in latch processes,
                -- then back to WAIT for the next packet.
                next_state <= S_WAIT;
        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Outputs
    ----------------------------------------------------------------------------
    o_auth_ok    <= r_auth_ok;
    o_auth_valid <= r_auth_vld;

end architecture;
