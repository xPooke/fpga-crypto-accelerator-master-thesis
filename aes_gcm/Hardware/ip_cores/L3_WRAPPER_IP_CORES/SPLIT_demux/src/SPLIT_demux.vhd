----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : SPLIT_demux
-- Module Name   : SPLIT_demux - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Splits a byte-contiguous input stream into two AXIS masters:
--                   m_bypass : first BYPASS_BYTES (bypass segment) - untouched
--                   m_crypto : AAD || PT  -> into the AES-GCM core
--                 BYPASS_BYTES / AAD_BYTES are not multiples of the bus width
--                 in general, so AAD (and PT) start mid-beat on the input. A
--                 gearbox (r_gearbox) re-aligns each downstream segment so it
--                 starts at byte 0 of its own output stream.
--
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
--
-- Revision      :
--   0.01 - July 2026 - File Created
--   0.02 - August 2026 - Bypass = 0 is now supported: added the BYPASS_EN
--          generic. When false the bypass segment is disabled entirely - no
--          m_bypass stream, the FSM skips S_BYPASS, and AAD starts at byte 0
--          (c_EFF_BYPASS = 0). BYPASS_BYTES applies only when BYPASS_EN = true.
--
-- Additional Comments :
--   Active-low reset (i_rstn).
--   AXIS byte order: lane 0 = TDATA[7:0] = first/oldest byte; the gearbox is
--   right-aligned (oldest carried byte at the LSB).
--   Written/verified for the NON-aligned case (e.g. 50/20). Aligned corner
--   cases (c_GAP_AFTER_BYPASS or c_GAP_AFTER_AAD = 0) rely on null-range slices
--   acting as no-ops - confirm in simulation or wrap in if-generate first.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.all;
use work.util_split.all;


entity SPLIT_demux is
    generic (
        DATA_WIDTH  : positive := 128;
        BYPASS_EN   : boolean  := true; -- true = bypass segment present (as before);
                                        -- false = disabled, no m_bypass stream at all
        BYPASS_BYTES: positive := 50;   -- bypass segment bytes (used only when BYPASS_EN)
        AAD_BYTES   : positive := 20    -- AAD bytes
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;

        -- AXIS slave (upstream side)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);

        -- AXIS master: bypass (bypass segment, untouched)
        m_bypass_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_bypass_axis_tvalid : out std_logic;
        m_bypass_axis_tlast  : out std_logic;
        m_bypass_axis_tready : in  std_logic;
        m_bypass_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);

        -- AXIS master: crypto (AAD || PT) into the AES-GCM core
        m_crypto_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_crypto_axis_tvalid : out std_logic;
        m_crypto_axis_tlast  : out std_logic;
        m_crypto_axis_tready : in  std_logic;
        m_crypto_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0)
    );
end entity;

architecture rtl of SPLIT_demux is

    ----------------------------------------------------------------------------
    -- Constants
    ----------------------------------------------------------------------------
    constant c_BUS_BYTES      : positive := DATA_WIDTH / 8;                        -- 16

    -- Effective bypass length that drives the gearbox gap arithmetic. When the
    -- segment is disabled it is 0, so AAD starts at byte 0 of the crypto stream
    -- (the same geometry as an aligned zero-gap bypass).
    constant c_EFF_BYPASS     : natural  := BYPASS_BYTES * boolean'pos(BYPASS_EN);

    constant c_BYPASS_BEATS   : positive := calc_beats(BYPASS_BYTES, DATA_WIDTH);
    constant c_AAD_BEATS      : positive := calc_beats(AAD_BYTES,    DATA_WIDTH);
    constant c_MAX_BEATS      : positive := max(c_BYPASS_BEATS, c_AAD_BEATS);
    constant c_CNT_WIDTH      : positive := clog2(c_MAX_BEATS);
    constant c_BYPASS_ALIGNED : boolean  := is_aligned(BYPASS_BYTES, DATA_WIDTH);

    -- Carry size after the bypass segment = AAD seed = carry held during S_AAD.
    constant c_GAP_AFTER_BYPASS : natural := calc_gap(c_EFF_BYPASS, DATA_WIDTH);
    -- Carry size after bypass+AAD = PT seed = carry held during S_DATA.
    constant c_GAP_AFTER_AAD    : natural := calc_gap(c_EFF_BYPASS + AAD_BYTES, DATA_WIDTH);

    -- Valid bytes in the last (partial) beat of each fixed-length segment.
    constant c_BYP_REM : positive := ((BYPASS_BYTES - 1) mod c_BUS_BYTES) + 1;  
    constant c_AAD_REM : positive := ((AAD_BYTES    - 1) mod c_BUS_BYTES) + 1;  

    -- Is the last AAD beat fully covered by the gearbox (DRAIN) or does it still
    -- need one more input beat (COMBINE)? Compile-time decision.
    constant c_AAD_LAST_IS_DRAIN : boolean := (c_GAP_AFTER_BYPASS >= c_AAD_REM);

    ----------------------------------------------------------------------------
    -- FSM
    --   S_DATA  : PT       for ENC / CT + ICV for DEC
    --   S_FLUSH : PT tail that overflowed past the last input beat
    ----------------------------------------------------------------------------
    type state_t is (S_BYPASS, S_AAD, S_DATA, S_FLUSH);

    -- Start (and inter-packet idle) state. When the bypass segment is disabled the
    -- FSM skips S_BYPASS entirely and lives on S_AAD/S_DATA/S_FLUSH only.
    function init_state (en : boolean) return state_t is
    begin
        if en then return S_BYPASS; else return S_AAD; end if;
    end function;

    constant c_INIT_STATE : state_t := init_state(BYPASS_EN);

    signal state_reg, next_state : state_t := c_INIT_STATE;

    ----------------------------------------------------------------------------
    -- Gearbox (re-alignment carry, right-aligned at the LSB)
    ----------------------------------------------------------------------------
    signal r_gearbox       : std_logic_vector(DATA_WIDTH-1 downto 0)   := (others => '0');  -- carried data bytes
    signal r_tkeep_gearbox : std_logic_vector(DATA_WIDTH/8-1 downto 0) := (others => '0');  -- carried byte-valid mask

    ----------------------------------------------------------------------------
    -- Segment output-beat counter
    ----------------------------------------------------------------------------
    signal r_cnt : unsigned(c_CNT_WIDTH-1 downto 0) := (others => '0');  -- emitted beats in current segment

    ----------------------------------------------------------------------------
    -- End-of-input tracker
    ----------------------------------------------------------------------------
    signal r_in_last : std_logic := '0';  -- input TLAST already consumed this packet

    ----------------------------------------------------------------------------
    -- Combinational control
    ----------------------------------------------------------------------------
    signal w_last_bypass      : std_logic;  -- current beat is the last bypass beat
    signal w_last_aad         : std_logic;  -- current beat is the last AAD beat
    signal w_bypass_handshake : std_logic;  -- bypass master beat accepted
    signal w_crypto_handshake : std_logic;  -- crypto master beat accepted
    signal w_slave_handshake  : std_logic;  -- input beat accepted
    signal w_in_done          : std_logic;  -- input is exhausted (TLAST consumed)

begin

    --------------------------------------------------------------------------
    -- Segment-last flags
    --------------------------------------------------------------------------
    p_SEG_FLAGS : process(state_reg, r_cnt)
    begin
        w_last_bypass <= '0';
        w_last_aad    <= '0';

        if state_reg = S_BYPASS and
           r_cnt = to_unsigned(c_BYPASS_BEATS-1, r_cnt'length) then
            w_last_bypass <= '1';
        end if;

        if state_reg = S_AAD and
           r_cnt = to_unsigned(c_AAD_BEATS-1, r_cnt'length) then
            w_last_aad <= '1';
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Gearbox: capture / shift the carried bytes (newest input bytes, stored
    -- right-aligned so they become the LSBs of the next output beat).
    --------------------------------------------------------------------------
    p_GEARBOX : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_gearbox       <= (others => '0');
                r_tkeep_gearbox <= (others => '0');
            else
                case state_reg is

                    -- Last bypass beat: park the top c_GAP_AFTER_BYPASS bytes (AAD seed).
                    when S_BYPASS =>
                        if w_last_bypass = '1' and w_bypass_handshake = '1' then
                            r_gearbox(c_GAP_AFTER_BYPASS*8 - 1 downto 0)
                                <= s_axis_tdata(DATA_WIDTH-1 downto DATA_WIDTH - c_GAP_AFTER_BYPASS*8);
                            r_tkeep_gearbox(c_GAP_AFTER_BYPASS - 1 downto 0)
                                <= s_axis_tkeep(DATA_WIDTH/8-1 downto DATA_WIDTH/8 - c_GAP_AFTER_BYPASS);
                        end if;

                    when S_AAD =>
                        if w_crypto_handshake = '1' then
                            if w_last_aad = '0' then
                                -- Intermediate COMBINE: carry = top c_GAP_AFTER_BYPASS input bytes.
                                r_gearbox(c_GAP_AFTER_BYPASS*8 - 1 downto 0)
                                    <= s_axis_tdata(DATA_WIDTH-1 downto DATA_WIDTH - c_GAP_AFTER_BYPASS*8);
                                r_tkeep_gearbox(c_GAP_AFTER_BYPASS - 1 downto 0)
                                    <= s_axis_tkeep(DATA_WIDTH/8-1 downto DATA_WIDTH/8 - c_GAP_AFTER_BYPASS);
                            else
                                -- Last AAD beat: leave c_GAP_AFTER_AAD bytes behind (PT seed).
                                if c_AAD_LAST_IS_DRAIN then
                                    -- DRAIN: shift the gearbox down by c_AAD_REM bytes.
                                    r_gearbox(c_GAP_AFTER_AAD*8 - 1 downto 0)
                                        <= r_gearbox(c_GAP_AFTER_BYPASS*8 - 1 downto c_AAD_REM*8);
                                    r_tkeep_gearbox(c_GAP_AFTER_AAD - 1 downto 0)
                                        <= r_tkeep_gearbox(c_GAP_AFTER_BYPASS - 1 downto c_AAD_REM);
                                else
                                    -- COMBINE: carry = top c_GAP_AFTER_AAD input bytes.
                                    r_gearbox(c_GAP_AFTER_AAD*8 - 1 downto 0)
                                        <= s_axis_tdata(DATA_WIDTH-1 downto (c_AAD_REM-c_GAP_AFTER_BYPASS)*8);
                                    r_tkeep_gearbox(c_GAP_AFTER_AAD - 1 downto 0)
                                        <= s_axis_tkeep(DATA_WIDTH/8-1 downto (c_AAD_REM-c_GAP_AFTER_BYPASS));
                                end if;
                            end if;
                        end if;

                    when S_DATA =>
                        if w_crypto_handshake = '1' then
                            if s_axis_tlast = '0' then
                                -- Streaming COMBINE: carry = top c_GAP_AFTER_AAD input bytes.
                                r_gearbox(c_GAP_AFTER_AAD*8 - 1 downto 0)
                                    <= s_axis_tdata(DATA_WIDTH-1 downto DATA_WIDTH - c_GAP_AFTER_AAD*8);
                                r_tkeep_gearbox(c_GAP_AFTER_AAD - 1 downto 0)
                                    <= s_axis_tkeep(DATA_WIDTH/8-1 downto DATA_WIDTH/8 - c_GAP_AFTER_AAD);
                            elsif (c_GAP_AFTER_AAD + keep_bytes(s_axis_tkeep)) > c_BUS_BYTES then
                                -- TLAST overflow: stash the tail for S_FLUSH (tkeep marks valid bytes).
                                r_gearbox(c_GAP_AFTER_AAD*8 - 1 downto 0)
                                    <= s_axis_tdata(DATA_WIDTH-1 downto DATA_WIDTH - c_GAP_AFTER_AAD*8);
                                r_tkeep_gearbox(c_GAP_AFTER_AAD - 1 downto 0)
                                    <= s_axis_tkeep(DATA_WIDTH/8-1 downto DATA_WIDTH/8 - c_GAP_AFTER_AAD);
                            end if;
                        end if;

                    when S_FLUSH =>
                        null;
                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Segment output-beat counter
    --------------------------------------------------------------------------
    p_CNT : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_cnt <= (others => '0');
            else
                case state_reg is

                    when S_BYPASS =>
                        if w_bypass_handshake = '1' then
                            if w_last_bypass = '1' then
                                r_cnt <= (others => '0');
                            else
                                r_cnt <= r_cnt + 1;
                            end if;
                        end if;

                    when S_AAD =>
                        if w_crypto_handshake = '1' then
                            if w_last_aad = '1' then
                                r_cnt <= (others => '0');
                            else
                                r_cnt <= r_cnt + 1;
                            end if;
                        end if;

                    when others =>
                        r_cnt <= (others => '0');

                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- End-of-input tracker: latched once the input TLAST beat is consumed,
    -- cleared when the packet leaves the crypto master.
    --------------------------------------------------------------------------
    p_IN_LAST : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_in_last <= '0';
            else
                if w_slave_handshake = '1' and s_axis_tlast = '1' then
                    r_in_last <= '1';
                end if;
                if state_reg /= c_INIT_STATE and next_state = c_INIT_STATE then
                    r_in_last <= '0';
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM state register
    --------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                state_reg <= c_INIT_STATE;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM next-state logic
    --------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, w_last_bypass, w_last_aad, w_bypass_handshake,
                           w_crypto_handshake, w_in_done, s_axis_tlast, s_axis_tkeep)
    begin
        next_state <= state_reg;
        case state_reg is

            when S_BYPASS =>
                if w_last_bypass = '1' and w_bypass_handshake = '1' then
                    next_state <= S_AAD;
                end if;

            when S_AAD =>
                if w_last_aad = '1' and w_crypto_handshake = '1' then
                    if w_in_done = '1' then
                        -- The whole PT fitted in the beat that carried the AAD
                        -- tail: it already sits in the gearbox, drain it.
                        next_state <= S_FLUSH;
                    else
                        next_state <= S_DATA;
                    end if;
                end if;

            when S_DATA =>
                if w_crypto_handshake = '1' and s_axis_tlast = '1' then
                    if (c_GAP_AFTER_AAD + keep_bytes(s_axis_tkeep)) > c_BUS_BYTES then
                        next_state <= S_FLUSH;   -- tail overflowed, one more beat needed
                    else
                        next_state <= c_INIT_STATE;  -- this beat was already the last one
                    end if;
                end if;

            when S_FLUSH =>
                if w_crypto_handshake = '1' then
                    next_state <= c_INIT_STATE;
                end if;
        end case;
    end process;

    --------------------------------------------------------------------------
    -- Slave side: ready follows whichever master is active, but back-pressures
    -- whenever a beat is emitted purely from the gearbox (the AAD DRAIN beat,
    -- or the S_FLUSH beat). w_in_done reports the end of the input stream and
    -- already accounts for the TLAST beat being consumed in this very cycle.
    --------------------------------------------------------------------------
    p_SLAVE_IN : process(state_reg, w_last_aad, r_in_last, s_axis_tvalid, s_axis_tlast,
                         m_bypass_axis_tready, m_crypto_axis_tready)
        variable v_tready : std_logic;
        variable v_hs     : std_logic;
    begin
        if BYPASS_EN and state_reg = S_BYPASS then
            v_tready := m_bypass_axis_tready;
        elsif state_reg = S_FLUSH then
            v_tready := '0';
        elsif w_last_aad = '1' and c_AAD_LAST_IS_DRAIN then
            v_tready := '0';
        else
            v_tready := m_crypto_axis_tready;
        end if;

        v_hs := s_axis_tvalid and v_tready;

        s_axis_tready     <= v_tready;
        w_slave_handshake <= v_hs;
        w_in_done         <= r_in_last or (v_hs and s_axis_tlast);
    end process;

    --------------------------------------------------------------------------
    -- Bypass master: aligned passthrough of the first BYPASS_BYTES.
    --------------------------------------------------------------------------
    p_BYPASS_OUT : process(state_reg, w_last_bypass, s_axis_tdata, s_axis_tvalid,
                           m_bypass_axis_tready)
        variable v_tvalid : std_logic;
        variable v_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    begin
        if BYPASS_EN then
            if state_reg = S_BYPASS then
                v_tvalid := s_axis_tvalid;
            else
                v_tvalid := '0';
            end if;

            if w_last_bypass = '1' then
                v_tkeep := keep_mask(c_BYP_REM, c_BUS_BYTES);
            else
                v_tkeep := (others => '1');
            end if;

            m_bypass_axis_tdata  <= s_axis_tdata;
            m_bypass_axis_tkeep  <= v_tkeep;
            m_bypass_axis_tvalid <= v_tvalid;
            m_bypass_axis_tlast  <= w_last_bypass;

            w_bypass_handshake   <= v_tvalid and m_bypass_axis_tready;
        else
            -- Bypass disabled: no stream on this master at all.
            m_bypass_axis_tdata  <= (others => '0');
            m_bypass_axis_tkeep  <= (others => '0');
            m_bypass_axis_tvalid <= '0';
            m_bypass_axis_tlast  <= '0';

            w_bypass_handshake   <= '0';
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Crypto master: AAD || PT, re-aligned to byte 0 of its own stream. Valid is
    -- forced high while emitting purely from the gearbox (the AAD DRAIN beat or
    -- S_FLUSH); otherwise it follows the input.
    --------------------------------------------------------------------------
    p_CRYPTO_OUT : process(state_reg, w_last_aad, r_gearbox, r_tkeep_gearbox,
                           s_axis_tdata, s_axis_tkeep, s_axis_tvalid, s_axis_tlast,
                           m_crypto_axis_tready)
        variable v_data   : std_logic_vector(DATA_WIDTH-1 downto 0);
        variable v_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
        variable v_tvalid : std_logic;
        variable v_tlast  : std_logic;
        variable v_nbytes : natural;
    begin
        v_data   := (others => '0');
        v_tkeep  := (others => '0');
        v_tvalid := '0';
        v_tlast  := '0';

        case state_reg is

            when S_AAD =>
                if w_last_aad = '0' then
                    -- Intermediate: gearbox(low c_GAP_AFTER_BYPASS) ++ input(low 16-gap).
                    v_data(c_GAP_AFTER_BYPASS*8-1 downto 0)          := r_gearbox(c_GAP_AFTER_BYPASS*8-1 downto 0);
                    v_data(DATA_WIDTH-1 downto c_GAP_AFTER_BYPASS*8) := s_axis_tdata((c_BUS_BYTES-c_GAP_AFTER_BYPASS)*8-1 downto 0);
                    v_tkeep  := (others => '1');
                    v_tvalid := s_axis_tvalid;
                else
                    -- Last AAD beat (c_AAD_REM valid bytes).
                    if c_AAD_LAST_IS_DRAIN then
                        v_data(c_AAD_REM*8-1 downto 0) := r_gearbox(c_AAD_REM*8-1 downto 0);
                        v_tvalid := '1';
                    else
                        v_data(c_GAP_AFTER_BYPASS*8-1 downto 0)           := r_gearbox(c_GAP_AFTER_BYPASS*8-1 downto 0);
                        v_data(c_AAD_REM*8-1 downto c_GAP_AFTER_BYPASS*8) := s_axis_tdata((c_AAD_REM-c_GAP_AFTER_BYPASS)*8-1 downto 0);
                        v_tvalid := s_axis_tvalid;
                    end if;
                    v_tkeep := keep_mask(c_AAD_REM, c_BUS_BYTES);
                end if;

            when S_DATA =>
                v_nbytes := keep_bytes(s_axis_tkeep);
                v_data(c_GAP_AFTER_AAD*8-1 downto 0)          := r_gearbox(c_GAP_AFTER_AAD*8-1 downto 0);
                v_data(DATA_WIDTH-1 downto c_GAP_AFTER_AAD*8) := s_axis_tdata((c_BUS_BYTES-c_GAP_AFTER_AAD)*8-1 downto 0);

                if s_axis_tlast = '1' and (c_GAP_AFTER_AAD + v_nbytes) < c_BUS_BYTES then
                    -- Short last beat, no flush follows.
                    v_tkeep := keep_mask(c_GAP_AFTER_AAD + v_nbytes, c_BUS_BYTES);
                else
                    -- Full beat (a flush beat may follow).
                    v_tkeep := (others => '1');
                end if;

                if s_axis_tlast = '1' and (c_GAP_AFTER_AAD + v_nbytes) <= c_BUS_BYTES then
                    v_tlast := '1';
                end if;

                v_tvalid := s_axis_tvalid;

            when S_FLUSH =>
                -- Tail sits in the low bytes. Only the low c_GAP_AFTER_AAD bits
                -- of r_tkeep_gearbox are refreshed on the stash; mask off the
                -- stale upper bits left over from earlier segments.
                v_data   := r_gearbox;
                v_tkeep  := r_tkeep_gearbox and keep_mask(c_GAP_AFTER_AAD, c_BUS_BYTES);
                v_tvalid := '1';
                v_tlast  := '1';

            when others =>
                null;

        end case;

        m_crypto_axis_tdata  <= v_data;
        m_crypto_axis_tkeep  <= v_tkeep;
        m_crypto_axis_tvalid <= v_tvalid;
        m_crypto_axis_tlast  <= v_tlast;

        w_crypto_handshake   <= v_tvalid and m_crypto_axis_tready;
    end process;

end architecture;
