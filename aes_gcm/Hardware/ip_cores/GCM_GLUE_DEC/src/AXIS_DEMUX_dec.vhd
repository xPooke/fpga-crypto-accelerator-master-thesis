--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : axis_demux_dec
-- Module Name   : axis_demux_dec - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : Demuxes the GCM decrypt path's inbound AXIS stream
--                 (AAD || CT || ICV, with TLAST only on the ICV beat)
--                 into three separate master streams:
--                   m_aad  - passthrough during the first AAD_BEATS beats
--                   m_ct   - delayed 1 beat through a skid buffer so
--                            m_ct_tlast can fire on the real last CT
--                            (which is only knowable when the ICV arrives)
--                   m_icv  - captured into r_icv_t* on the ICV cycle,
--                            emitted afterwards in S_EMIT_ICV
--                 Side-band to GHASH_wrapper carries the AAD / CT bit
--                 lengths:
--                   o_ct_bit_len is driven from a registered value
--                     r_ct_bit_len = (r_ct_cnt - 1) * 128
--                                  + keep_bits(r_buf_tkeep)
--                     latched on the ICV-arrival cycle.
--                   o_len_valid is registered and pulses one cycle
--                     after the ICV arrives, aligned with the latched
--                     length.
--                 When AAD_BEATS = 0 the FSM starts in S_CT_FIRST and
--                 S_AAD is skipped.
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
-- Revision      : 0.01 - May 2026 - File created
--                 0.02 - July 2026 - AAD_BYTES generic added; o_aad_bit_len is
--                 now derived from it instead of AAD_BEATS * DATA_WIDTH, since
--                 the AAD length need not be a multiple of the bus width.
-- Additional Comments :
--                 Active-low reset.
--                 S_CT_FIRST exists only to prime the skid buffer
--                 (the first CT enters r_buf without emitting).
--                 TLAST recovery: if TLAST=1 arrives in S_AAD or
--                 S_CT_FIRST the FSM resets to c_START_STATE.
--                 aad_last() returns 0 when AAD_BEATS=0 to avoid an
--                 illegal NATURAL argument to to_unsigned at
--                 elaboration; unused at run time.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_demux_dec is
    generic (
        AAD_BEATS  : natural  := 2;
        AAD_BYTES  : natural  := 20;
        DATA_WIDTH : positive := 128
    );
    port (
        i_clk          : in  std_logic;
        i_rstn         : in  std_logic;

        -- AXIS slave: AAD || CT || ICV (TLAST=1 on ICV beat)
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

        -- AXIS master: CT output (TLAST=1 on last CT beat, internally generated)
        m_ct_tdata     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_ct_tkeep     : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_ct_tvalid    : out std_logic;
        m_ct_tlast     : out std_logic;
        m_ct_tready    : in  std_logic;

        -- AXIS master: ICV output (one beat, emitted after last CT)
        m_icv_tdata    : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_icv_tkeep    : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_icv_tvalid   : out std_logic;
        m_icv_tlast    : out std_logic;
        m_icv_tready   : in  std_logic;

        -- Side-band: lengths to GHASH wrapper
        o_aad_bit_len  : out std_logic_vector(63 downto 0);
        o_ct_bit_len   : out std_logic_vector(63 downto 0);
        o_len_valid    : out std_logic
    );
end entity;

architecture rtl of axis_demux_dec is

    ------------------------------------------------------------------
    -- Number of valid BITS in a beat, from its tkeep (8 per kept byte).
    -- Full beat -> DATA_WIDTH, so full-block packets are unchanged.
    ------------------------------------------------------------------
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

    ------------------------------------------------------------------
    -- FSM states (4 states: AAD, CT_FIRST, CT_STREAM, EMIT_ICV)
    ------------------------------------------------------------------
    type state_t is (S_AAD, S_CT_FIRST, S_CT_STREAM, S_EMIT_ICV);

    ------------------------------------------------------------------
    -- AAD=0 support helpers
    -- aad_last : "last AAD index" used in the S_AAD beat-count compare.
    --            When AAD_BEATS=0 this returns 0 instead of computing
    --            AAD_BEATS-1 (= -1), which would be an illegal NATURAL
    --            argument to to_unsigned and fail at elaboration. S_AAD
    --            is never entered when AAD_BEATS=0, so the value is unused
    --            at run time; it only needs to be a legal constant.
    -- init_state : start state. With no AAD we skip the AAD phase entirely
    --            and begin in S_CT_FIRST.
    ------------------------------------------------------------------
    function aad_last(n : natural) return natural is
    begin
        if n = 0 then
            return 0;
        else
            return n - 1;
        end if;
    end function;

    function init_state(n : natural) return state_t is
    begin
        if n = 0 then
            return S_CT_FIRST;
        else
            return S_AAD;
        end if;
    end function;

    constant c_AAD_LAST    : natural := aad_last(AAD_BEATS);
    constant c_START_STATE : state_t := init_state(AAD_BEATS);

    signal state_reg  : state_t := c_START_STATE;
    signal next_state : state_t := c_START_STATE;

    signal r_aad_cnt : unsigned(7 downto 0)  := (others => '0');
    signal r_ct_cnt  : unsigned(56 downto 0) := (others => '0');

    -- Sliding window register (delay slot for CT)
    signal r_buf_tdata : std_logic_vector(DATA_WIDTH-1 downto 0)   := (others => '0');
    signal r_buf_tkeep : std_logic_vector(DATA_WIDTH/8-1 downto 0) := (others => '0');

    -- ICV buffer (captured at end of S_CT_STREAM, emitted in S_EMIT_ICV)
    signal r_icv_tdata : std_logic_vector(DATA_WIDTH-1 downto 0)   := (others => '0');
    signal r_icv_tkeep : std_logic_vector(DATA_WIDTH/8-1 downto 0) := (others => '0');

    -- Final CT bit length (latched at end of CT stream)
    signal r_ct_bit_len  : std_logic_vector(63 downto 0) := (others => '0');

    -- Registered o_len_valid strobe: 1-cycle pulse one cycle after r_ct_bit_len
    -- captures its new value, keeping them aligned at the output.
    signal r_o_len_valid : std_logic := '0';

    -- Internal wires mirroring master/slave AXIS port signals
    signal w_slave_tready : std_logic;
    signal w_aad_tvalid  : std_logic;
    signal w_ct_tvalid   : std_logic;
    signal w_ct_tlast    : std_logic;
    signal w_icv_tvalid  : std_logic;
    signal w_icv_tlast   : std_logic;

    signal w_slave_handshake   : std_logic;
    signal w_is_last_in   : std_logic;
    signal w_icv_handshake     : std_logic;

    -- Combinational CT bit length, valid on the ICV-arrival cycle.
    --   (r_ct_cnt - 1) full beats * 128  +  valid bits of the last CT (r_buf)
    signal w_ct_bit_len_comb : std_logic_vector(63 downto 0);

begin

    ----------------------------------------------------------------------------
    -- AAD bit length: constant from generic (0 when AAD_BYTES=0)
    ----------------------------------------------------------------------------
    o_aad_bit_len <= std_logic_vector(to_unsigned(AAD_BYTES * 8, 64));

    ----------------------------------------------------------------------------
    -- Detect ICV beat arriving (combinational): used for m_ct_tlast, capture,
    -- AND for presenting the length one cycle early (see below).
    ----------------------------------------------------------------------------
    w_is_last_in <= '1' when (state_reg = S_CT_STREAM and
                              s_axis_tvalid = '1' and
                              s_axis_tlast = '1')
                     else '0';

    ----------------------------------------------------------------------------
    -- CT bit length, computed combinationally so it is valid on the SAME cycle
    -- the ICV arrives (w_is_last_in). r_ct_cnt and r_buf_tkeep already hold the
    -- final values on that cycle, so this equals the registered computation.
    ----------------------------------------------------------------------------
    w_ct_bit_len_comb <= std_logic_vector(
                              resize((r_ct_cnt - 1) & "0000000", 64)
                            + to_unsigned(keep_bits(r_buf_tkeep), 64));

    ----------------------------------------------------------------------------
    -- Side-band length to GHASH. Both signals are driven from registers:
    --   o_ct_bit_len <- r_ct_bit_len  (latched on the ICV-arrival cycle)
    --   o_len_valid  <- r_o_len_valid (1-cycle pulse, one cycle after the
    --                                  ICV-arrival cycle so it is aligned
    --                                  with the latched length)
    -- GHASH_wrapper sees a clean strobe that always coincides with valid
    -- length data on the same edge.
    ----------------------------------------------------------------------------
    o_len_valid  <= r_o_len_valid;
    o_ct_bit_len <= r_ct_bit_len;

    ----------------------------------------------------------------------------
    -- TREADY back to slave
    ----------------------------------------------------------------------------
    w_slave_tready <= m_aad_tready when state_reg = S_AAD        else
                      '1'          when state_reg = S_CT_FIRST   else
                      m_ct_tready  when state_reg = S_CT_STREAM  else
                      '0';  -- S_EMIT_ICV
    s_axis_tready  <= w_slave_tready;

    w_slave_handshake <= s_axis_tvalid and w_slave_tready;
    w_icv_handshake   <= w_icv_tvalid and m_icv_tready;

    ----------------------------------------------------------------------------
    -- AAD master output
    ----------------------------------------------------------------------------
    m_aad_tdata   <= s_axis_tdata;
    m_aad_tkeep   <= s_axis_tkeep;
    w_aad_tvalid <= s_axis_tvalid when state_reg = S_AAD else '0';
    m_aad_tvalid  <= w_aad_tvalid;

    ----------------------------------------------------------------------------
    -- CT master output (delayed by one beat via r_buf)
    -- NOTE: tkeep is propagated as-is. Zero-padding of the partial last block
    -- for GHASH is done downstream in axis_ghash_mux (the module that feeds the
    -- GHASH wrapper), so the CT that goes on to AES-CTR for decryption stays
    -- intact.
    ----------------------------------------------------------------------------
    m_ct_tdata    <= r_buf_tdata;
    m_ct_tkeep    <= r_buf_tkeep;
    w_ct_tvalid  <= s_axis_tvalid when state_reg = S_CT_STREAM else '0';
    w_ct_tlast   <= w_is_last_in;
    m_ct_tvalid   <= w_ct_tvalid;
    m_ct_tlast    <= w_ct_tlast;

    ----------------------------------------------------------------------------
    -- ICV master output (only in S_EMIT_ICV state, emits from buffer)
    ----------------------------------------------------------------------------
    m_icv_tdata   <= r_icv_tdata;
    m_icv_tkeep   <= r_icv_tkeep;
    w_icv_tvalid <= '1' when state_reg = S_EMIT_ICV else '0';
    w_icv_tlast  <= '1' when state_reg = S_EMIT_ICV else '0';
    m_icv_tvalid  <= w_icv_tvalid;
    m_icv_tlast   <= w_icv_tlast;

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
    p_NEXT_STATE : process(state_reg, w_slave_handshake, s_axis_tlast, r_aad_cnt,
                           w_icv_handshake)
    begin
        next_state <= state_reg;

        -- TLAST recovery in anomalous states (S_AAD, S_CT_FIRST)
        if w_slave_handshake = '1' and s_axis_tlast = '1' and
           (state_reg = S_AAD or state_reg = S_CT_FIRST) then
            next_state <= c_START_STATE;
        else
            case state_reg is
                when S_AAD =>
                    if w_slave_handshake = '1' and
                       r_aad_cnt = to_unsigned(c_AAD_LAST, r_aad_cnt'length) then
                        next_state <= S_CT_FIRST;
                    end if;

                when S_CT_FIRST =>
                    if w_slave_handshake = '1' then
                        next_state <= S_CT_STREAM;
                    end if;

                when S_CT_STREAM =>
                    if w_slave_handshake = '1' and s_axis_tlast = '1' then
                        next_state <= S_EMIT_ICV;
                    end if;

                when S_EMIT_ICV =>
                    if w_icv_handshake = '1' then
                        next_state <= c_START_STATE;
                    end if;
            end case;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM data path: state-dependent register updates (counters, buffers,
    -- captured ICV, registered CT bit length).
    ----------------------------------------------------------------------------
    p_FSM_DATA : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_aad_cnt    <= (others => '0');
                r_ct_cnt     <= (others => '0');
                r_buf_tdata  <= (others => '0');
                r_buf_tkeep  <= (others => '0');
                r_icv_tdata  <= (others => '0');
                r_icv_tkeep  <= (others => '0');
                r_ct_bit_len <= (others => '0');
            else
                -- TLAST recovery: zero counters when bailing out of anomalous states
                if w_slave_handshake = '1' and s_axis_tlast = '1' and
                   (state_reg = S_AAD or state_reg = S_CT_FIRST) then
                    r_aad_cnt <= (others => '0');
                    r_ct_cnt  <= (others => '0');
                else

                    case state_reg is

                        when S_AAD =>
                            if w_slave_handshake = '1' then
                                if r_aad_cnt = to_unsigned(c_AAD_LAST,
                                                           r_aad_cnt'length) then
                                    r_aad_cnt <= (others => '0');
                                else
                                    r_aad_cnt <= r_aad_cnt + 1;
                                end if;
                            end if;

                        when S_CT_FIRST =>
                            -- Capture first CT into r_buf (no emit yet)
                            if w_slave_handshake = '1' then
                                r_buf_tdata <= s_axis_tdata;
                                r_buf_tkeep <= s_axis_tkeep;
                                r_ct_cnt    <= to_unsigned(1, r_ct_cnt'length);
                            end if;

                        when S_CT_STREAM =>
                            if w_slave_handshake = '1' then
                                if s_axis_tlast = '1' then
                                    -- ICV beat arrived. r_buf holds the LAST CT
                                    -- beat (already emitted with TLAST=1).
                                    -- Capture ICV into buffer for next cycle.
                                    r_icv_tdata <= s_axis_tdata;
                                    r_icv_tkeep <= s_axis_tkeep;
                                    r_ct_bit_len <= w_ct_bit_len_comb;
                                else
                                    -- Normal CT beat: r_buf was emitted, new in r_buf
                                    r_buf_tdata <= s_axis_tdata;
                                    r_buf_tkeep <= s_axis_tkeep;
                                    r_ct_cnt    <= r_ct_cnt + 1;
                                end if;
                            end if;

                        when S_EMIT_ICV =>
                            -- Reset counters when leaving via ICV handshake
                            if w_icv_handshake = '1' then
                                r_aad_cnt <= (others => '0');
                                r_ct_cnt  <= (others => '0');
                            end if;

                    end case;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Length-strobe register: r_o_len_valid pulses one cycle after w_is_last_in,
    -- coinciding with the edge on which r_ct_bit_len's new value first appears
    -- on o_ct_bit_len.
    ----------------------------------------------------------------------------
    p_LEN_STROBE : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_o_len_valid <= '0';
            else
                r_o_len_valid <= w_is_last_in;
            end if;
        end if;
    end process;

end architecture;
