--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : axis_mux_dec
-- Module Name   : axis_mux_dec - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : Output mux for the GCM decrypt path. Joins the AAD beats
--                 (passthrough from the inbound stream) and the decrypted
--                 PT beats (from AES-CTR) into a single outbound AXIS
--                 stream in fixed order:
--                   S_AAD  -> S_PT   after AAD_BEATS handshakes
--                   S_PT   -> S_EMIT on the TLAST of the PT stream
--                   S_EMIT -> restart after the last beat is emitted
--                 The final PT beat is captured into a local register
--                 (r_last_t*) and HELD in S_EMIT until the auth result
--                 from Tag_Verifier is available. On that cycle, the held
--                 beat is emitted together with TLAST, o_dec_done and the
--                 latched o_auth_ok — all on the same handshake — so the
--                 consumer sees the verdict atomically with the last beat
--                 of the packet.
--                 When AAD_BEATS = 0 the FSM starts directly in S_PT
--                 (AAD is skipped entirely).
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 Active-low reset.
--                 o_dec_done also serves as the auth-result strobe — it
--                 pulses on the same handshake that emits TLAST and the
--                 latched o_auth_ok, so consumers can use it as their
--                 single "packet done + auth result available" signal.
--                 The auth result is captured into r_auth_pending /
--                 r_auth_ok_latch as soon as it arrives, regardless of
--                 FSM state, so back-pressure on the last beat does not
--                 lose the verdict.
--                 aad_last() returns 0 (instead of AAD_BEATS-1) when
--                 AAD_BEATS=0 to avoid an illegal NATURAL argument to
--                 to_unsigned at elaboration; the value is unused at run
--                 time because S_AAD is never entered in that case.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_mux_dec is
    generic (
        AAD_BEATS  : natural  := 2;
        DATA_WIDTH : positive := 128
    );
    port (
        i_clk          : in  std_logic;
        i_rstn         : in  std_logic;

        -- AXIS slave 1: AAD beats (from AAD broadcaster)
        s_aad_tdata    : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_aad_tkeep    : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_aad_tvalid   : in  std_logic;
        s_aad_tready   : out std_logic;

        -- AXIS slave 2: PT beats (from AES-CTR)
        s_pt_tdata     : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_pt_tkeep     : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_pt_tvalid    : in  std_logic;
        s_pt_tlast     : in  std_logic;
        s_pt_tready    : out std_logic;

        -- Side-band: auth result from Tag Verifier
        i_auth_ok      : in  std_logic;
        i_auth_valid   : in  std_logic;

        -- AXIS master: combined AAD || PT output
        m_axis_tdata   : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep   : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid  : out std_logic;
        m_axis_tlast   : out std_logic;
        m_axis_tready  : in  std_logic;

        -- Side-band: synchronized with TLAST handshake
        o_dec_done     : out std_logic;
        o_auth_ok      : out std_logic
    );
end entity;

architecture rtl of axis_mux_dec is

    ------------------------------------------------------------------
    -- FSM states.
    -- S_EMIT merges the former S_WAIT_AUTH + S_EMIT_LAST: it both waits
    -- for the auth result AND emits the held last PT beat on the SAME
    -- cycle the auth becomes available (combinationally), removing the
    -- one-cycle registered hop between the two old states.
    ------------------------------------------------------------------
    type state_t is (S_AAD, S_PT, S_EMIT);

    ------------------------------------------------------------------
    -- AAD=0 support helpers
    -- init_st  : start state. With no AAD we skip the AAD phase entirely
    --            and begin in S_PT.
    -- aad_last : "last AAD index" used in the S_AAD beat-count compare.
    --            When AAD_BEATS=0 this returns 0 instead of computing
    --            AAD_BEATS-1 (= -1), which would be an illegal NATURAL
    --            argument to to_unsigned and fail at elaboration. S_AAD is
    --            never entered when AAD_BEATS=0, so the value is unused at
    --            run time; it only needs to be a legal constant.
    ------------------------------------------------------------------
    function init_st(n : natural) return state_t is
    begin
        if n = 0 then
            return S_PT;
        else
            return S_AAD;
        end if;
    end function;

    function aad_last(n : natural) return natural is
    begin
        if n = 0 then
            return 0;
        else
            return n - 1;
        end if;
    end function;

    constant c_START_STATE : state_t := init_st(AAD_BEATS);
    constant c_AAD_LAST    : natural := aad_last(AAD_BEATS);

    signal state_reg  : state_t := c_START_STATE;
    signal next_state : state_t := c_START_STATE;

    signal r_aad_cnt : unsigned(7 downto 0) := (others => '0');

    -- Hold last PT beat (with TLAST=1)
    signal r_last_tdata : std_logic_vector(DATA_WIDTH-1 downto 0)   := (others => '0');
    signal r_last_tkeep : std_logic_vector(DATA_WIDTH/8-1 downto 0) := (others => '0');

    ------------------------------------------------------------------
    -- Auth latch - captures auth result whenever it arrives
    -- regardless of current FSM state. Still present so the auth result
    -- is held if it arrives before S_EMIT or is back-pressured.
    ------------------------------------------------------------------
    signal r_auth_pending  : std_logic := '0';
    signal r_auth_ok_latch : std_logic := '0';

    ------------------------------------------------------------------
    -- Internal helpers (with _1 suffix)
    ------------------------------------------------------------------
    signal w_aad_tready  : std_logic;
    signal w_pt_tready   : std_logic;
    signal w_master_tvalid : std_logic;
    signal w_master_tlast  : std_logic;
    signal w_dec_done    : std_logic;
    signal w_auth_ok     : std_logic;

    signal w_aad_handshake    : std_logic;
    signal w_pt_handshake     : std_logic;
    signal w_master_handshake : std_logic;

    -- Auth available THIS cycle = already latched (pending) or arriving live.
    signal w_auth_avail  : std_logic;
    -- Auth value to forward: latched copy if pending, else the live input.
    signal w_auth_ok_now : std_logic;

begin

    ----------------------------------------------------------------------------
    -- Auth availability (combinational), in any arrival order/timing
    ----------------------------------------------------------------------------
    w_auth_avail  <= r_auth_pending or i_auth_valid;
    w_auth_ok_now <= r_auth_ok_latch when r_auth_pending = '1' else i_auth_ok;

    ----------------------------------------------------------------------------
    -- Fire signals
    ----------------------------------------------------------------------------
    w_aad_handshake    <= s_aad_tvalid and w_aad_tready;
    w_pt_handshake     <= s_pt_tvalid  and w_pt_tready;
    w_master_handshake <= w_master_tvalid and m_axis_tready;

    ----------------------------------------------------------------------------
    -- AAD slave ready: only in S_AAD, follow master ready
    ----------------------------------------------------------------------------
    w_aad_tready <= m_axis_tready when state_reg = S_AAD else '0';
    s_aad_tready  <= w_aad_tready;

    ----------------------------------------------------------------------------
    -- PT slave ready:
    -- In S_PT, non-last beats: follow master ready
    -- In S_PT, last beat (TLAST=1): always accept (we capture into register)
    -- Other states: backpressure
    ----------------------------------------------------------------------------
    w_pt_tready <= m_axis_tready when (state_reg = S_PT and s_pt_tlast = '0') else
                    '1'           when (state_reg = S_PT and s_pt_tlast = '1') else
                    '0';
    s_pt_tready  <= w_pt_tready;

    ----------------------------------------------------------------------------
    -- Master output mux
    --   S_EMIT: drive the held last beat, valid only once auth is available.
    ----------------------------------------------------------------------------
    m_axis_tdata <= s_aad_tdata    when state_reg = S_AAD else
                    s_pt_tdata     when state_reg = S_PT  else
                    r_last_tdata;  -- S_EMIT

    m_axis_tkeep <= s_aad_tkeep    when state_reg = S_AAD else
                    s_pt_tkeep     when state_reg = S_PT  else
                    r_last_tkeep;

    w_master_tvalid <= s_aad_tvalid                     when state_reg = S_AAD else
                      (s_pt_tvalid and not s_pt_tlast) when state_reg = S_PT  else
                      w_auth_avail;  -- S_EMIT: emit held last beat once auth ready
    m_axis_tvalid <= w_master_tvalid;

    w_master_tlast <= '1' when state_reg = S_EMIT else '0';
    m_axis_tlast  <= w_master_tlast;

    ----------------------------------------------------------------------------
    -- Side-band outputs - asserted together with the emitted last beat
    ----------------------------------------------------------------------------
    w_dec_done   <= '1'           when (state_reg = S_EMIT and w_auth_avail = '1') else '0';
    w_auth_ok    <= w_auth_ok_now when (state_reg = S_EMIT and w_auth_avail = '1') else '0';

    o_dec_done   <= w_dec_done;
    o_auth_ok    <= w_auth_ok;

    ----------------------------------------------------------------------------
    -- Auth latch process - always-on capture
    -- Captures auth result whenever it arrives, regardless of FSM state.
    -- Cleared when the packet's last-beat handshake completes.
    ----------------------------------------------------------------------------
    p_AUTH_LATCH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_auth_pending  <= '0';
                r_auth_ok_latch <= '0';
            else
                -- Capture incoming auth result
                if i_auth_valid = '1' then
                    r_auth_pending  <= '1';
                    r_auth_ok_latch <= i_auth_ok;
                end if;

                -- Clear pending flag when packet completes (last-beat handshake)
                if state_reg = S_EMIT and w_master_handshake = '1' then
                    r_auth_pending <= '0';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM state register (sequential)
    ----------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                state_reg <= c_START_STATE;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM next-state logic (combinational)
    ----------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, w_aad_handshake, r_aad_cnt, w_pt_handshake,
                           s_pt_tlast, w_master_handshake)
    begin
        next_state <= state_reg;
        case state_reg is
            when S_AAD =>
                if w_aad_handshake = '1' and
                   r_aad_cnt = to_unsigned(c_AAD_LAST, r_aad_cnt'length) then
                    next_state <= S_PT;
                end if;
            when S_PT =>
                if w_pt_handshake = '1' and s_pt_tlast = '1' then
                    next_state <= S_EMIT;
                end if;
            when S_EMIT =>
                if w_master_handshake = '1' then
                    next_state <= c_START_STATE;
                end if;
        end case;
    end process;

    ----------------------------------------------------------------------------
    -- FSM data path: AAD counter, last-PT-beat capture
    ----------------------------------------------------------------------------
    p_FSM_DATA : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_aad_cnt    <= (others => '0');
                r_last_tdata <= (others => '0');
                r_last_tkeep <= (others => '0');
            else
                case state_reg is
                    when S_AAD =>
                        if w_aad_handshake = '1' then
                            if r_aad_cnt = to_unsigned(c_AAD_LAST,
                                                       r_aad_cnt'length) then
                                r_aad_cnt <= (others => '0');
                            else
                                r_aad_cnt <= r_aad_cnt + 1;
                            end if;
                        end if;

                    when S_PT =>
                        if w_pt_handshake = '1' and s_pt_tlast = '1' then
                            r_last_tdata <= s_pt_tdata;
                            r_last_tkeep <= s_pt_tkeep;
                        end if;

                    when S_EMIT =>
                        null;
                end case;
            end if;
        end if;
    end process;

end architecture;
