----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : May 2026
-- Design Name   : AES_pipelined_wrapper
-- Module Name   : AES_pipelined_wrapper - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : GCM-mode AES crypto wrapper around a single pipelined
--                 aes_enc_pipelined + KeyExpansion. Per packet: pushes
--                 H = AES_K(0), EK = AES_K(J0), then CT_i = PT_i XOR
--                 AES_K(J0+i) — back-to-back via a 2-bit dest_tag carried
--                 on aes_enc_pipelined's TUSER side-channel. Throughput:
--                 1 block / cycle in steady state. ROUND_STYLE selects
--                 BRAM T-tables or LUT for the main rounds (1..NR-1);
--                 the last round inside aes_enc_pipelined is always inline
--                 LUT. FLOW_STYLE picks GLOBAL or PER_STAGE pipeline
--                 flow control. Mid-packet shadow key + nonce apply at
--                 packet boundary. AES-128 and AES-256.
--
-- Dependencies  : work.aes_pkg, work.KeyExpansion, work.aes_enc_pipelined
--
-- Revision      :
--   0.01 - May 2026 - File Created
--
-- Additional Comments :
--   Active-low reset (i_rstn). On tlast CT handshake w_flush_all pulses
--   for one cycle: drives aes_enc_pipelined.i_flush, applies any pending
--   shadow key/nonce, and (if no shadow nonce is pending) clears
--   r_have_nonce as an IV-reuse guard — the user must explicitly pulse
--   i_nonce_valid before the next packet. Pipelined counterpart of
--   AES_multicore_wrapper (which uses NUM_CORES rolled cores instead).
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.aes_pkg.all;

entity AES_pipelined_wrapper is
    generic (
        AES_BITS    : integer := 128;      -- 128 or 256
        ROUND_STYLE : string  := "BRAM";    -- "BRAM" or "LUT"
        FLOW_STYLE  : string  := "GLOBAL"   -- "GLOBAL" or "PER_STAGE"
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;     -- active low

        -- Key + nonce config. i_key is the 256-bit caller-side key; the LSB
        -- AES_BITS bits are used internally as the AES key. i_nonce is the
        -- 96-bit GCM nonce; J0 = nonce || 0^31 || 1 is formed here, so the
        -- counter block can never be malformed by the caller.
        i_key         : in  std_logic_vector(255 downto 0);
        i_key_valid   : in  std_logic;     -- 1-cycle pulse for a new key
        i_nonce       : in  std_logic_vector(95 downto 0);
        i_nonce_valid : in  std_logic;     -- 1-cycle pulse for a new nonce

        -- AXIS slave (PT input)
        s_axis_tdata  : in  std_logic_vector(127 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tkeep  : in  std_logic_vector(15 downto 0);

        -- AXIS master (CT output)
        m_axis_tdata  : out std_logic_vector(127 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tkeep  : out std_logic_vector(15 downto 0);

        -- H output (for GHASH module)
        o_H           : out std_logic_vector(127 downto 0);
        o_H_valid     : out std_logic;

        -- E_K(J0) output (for tag mask in tag generator)
        o_E_k         : out std_logic_vector(127 downto 0);
        o_E_k_valid   : out std_logic;

        -- Side-band: '1' while the latched H is stale -- a key change is pending
        -- its recompute, so H = E_K(0) is not yet valid for the next packet.
        -- A downstream GHASH gate holds a packet's first beat while this is high.
        o_h_stale     : out std_logic;

        -- Side-band: '1' while any pipeline stage holds a valid block
        o_encryption_in_proc : out std_logic
    );
end entity;

architecture rtl of AES_pipelined_wrapper is

    ----------------------------------------------------------------------------
    -- TUSER encoding for the pipeline side-channel (dest_tag)
    ----------------------------------------------------------------------------
    constant c_TAG_CT : std_logic_vector(1 downto 0) := "00";
    constant c_TAG_H  : std_logic_vector(1 downto 0) := "01";
    constant c_TAG_EK : std_logic_vector(1 downto 0) := "10";

    ----------------------------------------------------------------------------
    -- FSM_KEY (per-key lifecycle; S_KS_LOAD gates H push until KE has K_0)
    ----------------------------------------------------------------------------
    type ks_state_t is (S_KS_IDLE, S_KS_LOAD, S_KS_ACTIVE);
    signal ks_state_reg  : ks_state_t := S_KS_IDLE;
    signal ks_next_state : ks_state_t := S_KS_IDLE;

    ----------------------------------------------------------------------------
    -- FSM_PACKET (per-packet lifecycle; drives nonce-shadowing decision)
    ----------------------------------------------------------------------------
    type ps_state_t is (S_PS_IDLE, S_PS_RUN);
    signal ps_state_reg  : ps_state_t := S_PS_IDLE;
    signal ps_next_state : ps_state_t := S_PS_IDLE;

    ----------------------------------------------------------------------------
    -- KeyExpansion interface
    ----------------------------------------------------------------------------
    signal r_active_key : std_logic_vector(AES_BITS-1 downto 0) := (others => '0');  -- latched active key
    signal w_padded_key : std_logic_vector(255 downto 0);                            -- r_active_key padded to 256b for KE port
    signal r_ke_new_key : std_logic := '0';                                          -- 1-cycle pulse to KE on new key
    signal w_round_keys : arr_round_keys_t;                                          -- KE output: K_0 .. K_NR

    ----------------------------------------------------------------------------
    -- 128-bit counter block: high 96 bits are the locked nonce, low 32 bits
    -- are the counter portion (incremented on every EK/CT push). J0 is built
    -- from i_nonce as nonce || 0^31 || 1 (NIST SP 800-38D, 96-bit nonce).
    ----------------------------------------------------------------------------
    signal w_J0         : std_logic_vector(127 downto 0);                    -- J0 = i_nonce || 0^31 || 1
    signal r_active_IV  : std_logic_vector(127 downto 0) := (others => '0');
    signal r_have_nonce : std_logic := '0';                                  -- '1' when r_active_IV is fresh (IV-reuse guard clears at packet end)

    ----------------------------------------------------------------------------
    -- Role flags (H / EK push + capture)
    ----------------------------------------------------------------------------
    signal r_h_pushed  : std_logic := '0';   -- H block has entered the pipeline
    signal r_ek_pushed : std_logic := '0';   -- EK block has entered the pipeline
    signal r_h_done    : std_logic := '0';   -- H output captured into r_H_reg
    signal r_ek_done   : std_logic := '0';   -- EK output captured into r_E_k_reg

    ----------------------------------------------------------------------------
    -- Shadow registers (apply at packet boundary if input arrived during S_PS_RUN)
    ----------------------------------------------------------------------------
    signal r_shadow_key         : std_logic_vector(AES_BITS-1 downto 0) := (others => '0');  -- pending key
    signal r_shadow_key_valid   : std_logic := '0';                                          -- pending key flag
    signal r_shadow_IV       : std_logic_vector(127 downto 0) := (others => '0');  -- pending IV
    signal r_shadow_IV_valid : std_logic := '0';                                   -- pending IV flag

    ----------------------------------------------------------------------------
    -- aes_enc_pipelined AXIS interface (TUSER width = 2)
    ----------------------------------------------------------------------------
    signal w_pipe_s_tdata  : std_logic_vector(127 downto 0);  -- pipeline input data
    signal w_pipe_s_tvalid : std_logic;                       -- pipeline input valid
    signal w_pipe_s_tready : std_logic;                       -- pipeline input ready
    signal w_pipe_s_tuser  : std_logic_vector(1 downto 0);    -- pipeline input tag (c_TAG_H/EK/CT)
    signal w_pipe_m_tdata  : std_logic_vector(127 downto 0);  -- pipeline output data
    signal w_pipe_m_tvalid : std_logic;                       -- pipeline output valid
    signal w_pipe_in_proc  : std_logic;                       -- pipeline-occupancy flag from the core
    signal w_pipe_m_tready : std_logic;                       -- pipeline output ready (drain)
    signal w_pipe_m_tuser  : std_logic_vector(1 downto 0);    -- pipeline output tag

    ----------------------------------------------------------------------------
    -- H / EK output staging
    ----------------------------------------------------------------------------
    signal r_H_reg     : std_logic_vector(127 downto 0) := (others => '0');  -- captured H = AES_K(0)
    signal r_E_k_reg   : std_logic_vector(127 downto 0) := (others => '0');  -- captured EK = AES_K(J0)
    signal r_H_pulse   : std_logic := '0';                                   -- 1-cycle valid on H capture
    signal r_E_k_pulse : std_logic := '0';                                   -- 1-cycle valid on EK capture

    ----------------------------------------------------------------------------
    -- Block scheduler outputs (combinational)
    ----------------------------------------------------------------------------
    signal w_sched_block : std_logic_vector(127 downto 0);  -- which block to push next
    signal w_sched_tag   : std_logic_vector(1 downto 0);    -- TUSER for that block
    signal w_sched_valid : std_logic;                       -- scheduler has something to push

    ----------------------------------------------------------------------------
    -- Internal handshake + flush helpers
    ----------------------------------------------------------------------------
    signal w_pipe_in_handshake  : std_logic;  -- block pushed into pipeline this cycle
    signal w_pipe_out_handshake : std_logic;  -- block leaves pipeline this cycle
    signal w_flush_all          : std_logic;  -- 1-cycle end-of-packet pulse (drives aes_enc_pipelined.i_flush)
    signal w_apply_shadow_IV : std_logic;  -- pulse on w_flush_all when only shadow_nonce pending
    signal w_rekey_at_flush     : std_logic;  -- pulse on w_flush_all when ANY key applies this cycle (shadow OR coincident i_key_valid)

begin

    --------------------------------------------------------------------------
    -- Generic validation
    --------------------------------------------------------------------------
    assert (AES_BITS = 128) or (AES_BITS = 256)
        report "AES_pipelined_wrapper: AES_BITS must be 128 or 256"
        severity failure;

    --------------------------------------------------------------------------
    -- J0 for a 96-bit nonce: nonce || 0^31 || 1 (NIST SP 800-38D)
    --------------------------------------------------------------------------
    w_J0 <= i_nonce & x"00000001";

    --------------------------------------------------------------------------
    -- Pad i_key to 256 bits for KeyExpansion (AES-128 occupies upper 128 bits)
    --------------------------------------------------------------------------
    gen_pad_128 : if AES_BITS = 128 generate
        -- AES-128: place 128-bit key in upper half (per KeyExpansion convention)
        w_padded_key <= r_active_key & x"00000000000000000000000000000000";
    end generate;
    gen_pad_256 : if AES_BITS = 256 generate
        w_padded_key <= r_active_key;
    end generate;

    --------------------------------------------------------------------------
    -- KeyExpansion instance
    --------------------------------------------------------------------------
    u_ke : entity work.KeyExpansion
        generic map (
            KEY_BITS => AES_BITS
        )
        port map (
            i_clk        => i_clk,
            i_rstn       => i_rstn,
            i_new_key    => r_ke_new_key,
            i_key        => w_padded_key,
            o_round_keys => w_round_keys
        );

    --------------------------------------------------------------------------
    -- aes_enc_pipelined instance (AES pipeline with TUSER side-channel)
    --------------------------------------------------------------------------
    u_pipe : entity work.aes_enc_pipelined
        generic map (
            AES_BITS    => AES_BITS,
            ROUND_STYLE => ROUND_STYLE,
            FLOW_STYLE  => FLOW_STYLE,
            TUSER_WIDTH => 2
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,
            i_flush       => w_flush_all,   -- 1-cycle pulse at tlast clears r_valid_vector
            i_keys        => w_round_keys,
            s_axis_tdata  => w_pipe_s_tdata,
            s_axis_tvalid => w_pipe_s_tvalid,
            s_axis_tready => w_pipe_s_tready,
            s_axis_tuser  => w_pipe_s_tuser,
            m_axis_tdata  => w_pipe_m_tdata,
            m_axis_tvalid => w_pipe_m_tvalid,
            m_axis_tready => w_pipe_m_tready,
            m_axis_tuser  => w_pipe_m_tuser,
            o_encryption_in_proc => w_pipe_in_proc
        );

    --------------------------------------------------------------------------
    -- Handshake helpers
    --------------------------------------------------------------------------
    w_pipe_in_handshake  <= w_pipe_s_tvalid and w_pipe_s_tready;
    w_pipe_out_handshake <= w_pipe_m_tvalid and w_pipe_m_tready;

    --------------------------------------------------------------------------
    -- Block scheduler (combinational): decides what goes into pipeline next.
    --
    -- Flag-driven so H/EK/CT pushes are back-to-back:
    --   1. H not yet pushed (and KE has loaded)   -> push 0^128, TUSER=H
    --   2. H pushed but EK not (and nonce ready)  -> push J0, TUSER=EK
    --   3. Both pushed (and nonce ready)          -> push counter, TUSER=CT
    --
    -- After tlast handshake, w_flush_all clears the pipeline and clears
    -- r_have_nonce (IV-reuse guard), which stops condition (3) naturally.
    --------------------------------------------------------------------------
    p_SCHEDULER : process(ks_state_reg, r_h_pushed, r_ek_pushed,
                          r_have_nonce, r_active_IV)
    begin
        -- defaults
        w_sched_block <= (others => '0');
        w_sched_tag   <= c_TAG_CT;
        w_sched_valid <= '0';

        if ks_state_reg = S_KS_ACTIVE and r_h_pushed = '0' then
            -- Push H = AES(0^128)
            w_sched_block <= (others => '0');
            w_sched_tag   <= c_TAG_H;
            w_sched_valid <= '1';

        elsif r_h_pushed = '1' and r_ek_pushed = '0' and r_have_nonce = '1' then
            -- Push J0 = full 128-bit IV (caller-supplied initial counter value)
            w_sched_block <= r_active_IV;
            w_sched_tag   <= c_TAG_EK;
            w_sched_valid <= '1';

        elsif r_h_pushed = '1' and r_ek_pushed = '1' and r_have_nonce = '1' then
            -- Push counter block = IV with its low-32-bit counter portion as
            -- it stands now (post EK/CT increment in p_DATA).
            w_sched_block <= r_active_IV;
            w_sched_tag   <= c_TAG_CT;
            w_sched_valid <= '1';
        end if;
    end process;

    -- Drive pipeline input from scheduler
    w_pipe_s_tdata  <= w_sched_block;
    w_pipe_s_tuser  <= w_sched_tag;
    w_pipe_s_tvalid <= w_sched_valid;

    --------------------------------------------------------------------------
    -- Output demux (combinational):
    --   * dest_tag = c_TAG_H or c_TAG_EK -> always-accept (lands in r_H / r_E_k)
    --   * dest_tag = c_TAG_CT          -> XOR with s_axis_tdata, propagate to
    --                                    m_axis along with TLAST/TKEEP
    --
    -- s_axis_tready goes high ONLY when a CT keystream is being presented at
    -- the pipeline output AND the downstream is ready.
    --------------------------------------------------------------------------
    p_OUTPUT_MUX : process(w_pipe_m_tvalid, w_pipe_m_tuser, w_pipe_m_tdata,
                           s_axis_tvalid, s_axis_tdata, s_axis_tlast,
                           s_axis_tkeep, m_axis_tready)
    begin
        -- defaults
        s_axis_tready    <= '0';
        m_axis_tvalid    <= '0';
        m_axis_tdata     <= (others => '0');
        m_axis_tlast     <= '0';
        m_axis_tkeep     <= (others => '0');
        w_pipe_m_tready  <= '1';   -- by default always drain pipeline

        if w_pipe_m_tvalid = '1' then
            case w_pipe_m_tuser is
                when c_TAG_H | c_TAG_EK =>
                    -- always accept (gets latched in sequential process)
                    w_pipe_m_tready <= '1';

                when c_TAG_CT =>
                    -- Stream zip (pipe_m keystream + s_axis PT -> m_axis CT).
                    -- AXI-compliant handshake: TVALID never depends on TREADY.
                    --   m_axis_tvalid : asserted when both inputs are valid
                    --                   (pipe_m_tvalid='1' is implicit here).
                    --   s_axis_tready : consume PT when downstream accepts.
                    --   pipe_m_tready : consume keystream when PT also present
                    --                   AND downstream accepts.
                    m_axis_tdata    <= w_pipe_m_tdata xor s_axis_tdata;
                    m_axis_tvalid   <= s_axis_tvalid;
                    m_axis_tlast    <= s_axis_tlast;
                    m_axis_tkeep    <= s_axis_tkeep;
                    s_axis_tready   <= m_axis_tready;
                    w_pipe_m_tready <= s_axis_tvalid and m_axis_tready;
                when others =>
                    null;
            end case;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Output H / EK registers + valid pulses
    --------------------------------------------------------------------------
    p_OUT_LATCH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_H_reg     <= (others => '0');
                r_E_k_reg   <= (others => '0');
                r_H_pulse   <= '0';
                r_E_k_pulse <= '0';
                r_h_done    <= '0';
                r_ek_done   <= '0';
            else
                -- pulses default low (single-cycle)
                r_H_pulse   <= '0';
                r_E_k_pulse <= '0';

                if w_pipe_out_handshake = '1' then
                    case w_pipe_m_tuser is
                        when c_TAG_H =>
                            r_H_reg   <= w_pipe_m_tdata;
                            r_H_pulse <= '1';
                            r_h_done  <= '1';
                        when c_TAG_EK =>
                            r_E_k_reg   <= w_pipe_m_tdata;
                            r_E_k_pulse <= '1';
                            r_ek_done   <= '1';
                        when others =>
                            null;
                    end case;
                end if;

                -- H-done clears on any key application (flush shadow/coincident, or an
                -- idle-direct key via r_ke_new_key). EK-done clears at packet end
                -- / on a renewed nonce -- re-captured once per packet, not per key pulse.
                if (w_rekey_at_flush = '1' or r_ke_new_key = '1') then
                    r_h_done  <= '0';
                end if;
                if (w_rekey_at_flush = '1' or w_apply_shadow_IV = '1') then
                    r_ek_done <= '0';
                end if;
            end if;
        end if;
    end process;

    o_H         <= r_H_reg;
    o_H_valid   <= r_H_pulse;
    o_E_k       <= r_E_k_reg;
    o_E_k_valid <= r_E_k_pulse;

    -- High whenever the latched H no longer matches the active key: r_h_done is
    -- set when H is captured and cleared on any key application.
    o_h_stale   <= not r_h_done;

    --------------------------------------------------------------------------
    -- Push/pushed flags
    --------------------------------------------------------------------------
    p_FLAGS : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_h_pushed  <= '0';
                r_ek_pushed <= '0';
            else
                -- Track which blocks have entered the pipeline
                if w_pipe_in_handshake = '1' then
                    case w_pipe_s_tuser is
                        when c_TAG_H  => r_h_pushed  <= '1';
                        when c_TAG_EK => r_ek_pushed <= '1';
                        when others => null;
                    end case;
                end if;

                -- Clear push flags on key apply OR at end of packet.
                --   * any key apply at flush (shadow or coincident pulse) ->
                --     KE re-runs, both H and EK must re-push.
                --   * any packet end -> next packet has its own J0/EK
                --                       (covers shadow_nonce and clean cases).
                -- H re-push on any key application (flush shadow/coincident, or an
                -- idle-direct key via r_ke_new_key). EK re-push on every packet end
                -- (w_flush_all; w_rekey_at_flush implies w_flush_all) -- once per
                -- packet, independent of key pulses.
                if (w_rekey_at_flush = '1' or r_ke_new_key = '1') then
                    r_h_pushed <= '0';
                end if;
                if w_flush_all = '1' then
                    r_ek_pushed <= '0';
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Counter generator + nonce/key latching
    --------------------------------------------------------------------------
    p_DATA : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_active_key       <= (others => '0');
                r_active_IV        <= (others => '0');
                r_have_nonce       <= '0';
                r_ke_new_key       <= '0';
                r_shadow_key       <= (others => '0');
                r_shadow_key_valid <= '0';
                r_shadow_IV        <= (others => '0');
                r_shadow_IV_valid  <= '0';
            else
                -- KE new_key is a 1-cycle pulse; default low, set on direct
                -- or shadow key apply below.
                r_ke_new_key <= '0';

                ----------------------------------------------------------------
                -- Incoming i_key / w_J0: latch into active or shadow
                ----------------------------------------------------------------
                if w_flush_all = '1' then
                    if r_shadow_key_valid = '1' then
                        r_active_key <= r_shadow_key;
                        r_ke_new_key <= '1';
                        if i_key_valid = '1' then
                            -- Latest-wins: a fresh key on the flush cycle overrides any staged shadow.
                            r_active_key       <= i_key(AES_BITS-1 downto 0);
                            r_ke_new_key       <= '1';
                        end if;
                        r_shadow_key_valid <= '0';

                    elsif i_key_valid = '1' then
                        -- Key on the flush cycle with no prior shadow: apply
                        -- directly so the next packet uses it.
                        r_active_key <= i_key(AES_BITS-1 downto 0);
                        r_ke_new_key <= '1';
                    end if;
                elsif i_key_valid = '1' then
                    -- Shadow the key once a packet is committed (have_nonce): a key
                    -- arriving while a packet is in flight defers to the next packet,
                    -- the same window the rolled wrapper uses (state_reg = S_RUN).
                    if r_have_nonce = '1' then
                        r_shadow_key       <= i_key(AES_BITS-1 downto 0);
                        r_shadow_key_valid <= '1';
                    else
                        r_active_key <= i_key(AES_BITS-1 downto 0);
                        r_ke_new_key <= '1';
                    end if;
                end if;

                -- i_nonce_valid capture is handled by the flush / non-flush block
                -- below (multicore-style).



   		  -- r_active_IV mutation: mutually exclusive priorities.
                if w_flush_all = '1' and ps_state_reg = S_PS_RUN then
                    -- Resolve the successor packet's IV. Invariant: an
                    -- i_nonce_valid pulse on the flush cycle is never dropped --
                    -- it either applies directly (latest-wins over any shadow), same as
                    -- the key chain.
                    if r_shadow_IV_valid = '1' then
                        r_active_IV      <= r_shadow_IV;
                        r_have_nonce <= '1';
                        if i_nonce_valid = '1' then
                            -- Latest-wins: a fresh IV on the flush cycle overrides any staged shadow.
                            r_active_IV       <= w_J0;
                            r_have_nonce <= '1';
                        end if;
                        r_shadow_IV_valid <= '0';

                    elsif i_nonce_valid = '1' then
                        -- IV arriving on the flush cycle with no prior shadow:
                        -- apply it directly so the next packet can start.
                        r_active_IV      <= w_J0;
                        r_have_nonce <= '1';
                    else
                        -- No shadow nonce: clear r_have_nonce so next packet
                        -- must explicitly pulse i_nonce_valid (IV-reuse guard).
                        r_have_nonce <= '0';
                    end if;
                else
                    if i_nonce_valid = '1' then
                        if r_have_nonce = '1' then
                            r_shadow_IV       <= w_J0;
                            r_shadow_IV_valid <= '1';
                        else
                            r_active_IV      <= w_J0;
                            r_have_nonce <= '1';
                        end if;
                    end if;
		    ----------------------------------------------------------------
		    -- inc32 on EK (J0) or CT push: the top 96 bits (nonce)
		    -- stay locked; only the low 32 bits advance.
		    ----------------------------------------------------------------
		    if w_pipe_in_handshake = '1' and
		    (w_pipe_s_tuser = c_TAG_EK or w_pipe_s_tuser = c_TAG_CT) then
	            	r_active_IV(31 downto 0) <=
                    		std_logic_vector(unsigned(r_active_IV(31 downto 0)) + 1);
		    end if;
		 end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM_KEY state register (sequential)
    --------------------------------------------------------------------------
    p_KS_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                ks_state_reg <= S_KS_IDLE;
            else
                ks_state_reg <= ks_next_state;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM_KEY next-state logic (combinational).
    -- S_KS_LOAD is the 1-cycle gate that prevents H push before KE LOAD has
    -- registered K_0. On entry to S_KS_ACTIVE the round keys are valid
    -- (K_0 always; K_1 too for AES-256 via LOAD pre-population).
    -- Any key apply on the w_flush_all cycle (shadow or coincident pulse)
    -- bounces back to S_KS_LOAD to re-run KE.
    --------------------------------------------------------------------------
    p_KS_NEXT_STATE : process(ks_state_reg, i_key_valid, w_rekey_at_flush, r_ke_new_key)
    begin
        ks_next_state <= ks_state_reg;
        case ks_state_reg is
            when S_KS_IDLE =>
                if i_key_valid = '1' then
                    ks_next_state <= S_KS_LOAD;
                end if;

            when S_KS_LOAD =>
                ks_next_state <= S_KS_ACTIVE;

            when S_KS_ACTIVE =>
                if (w_rekey_at_flush = '1' or r_ke_new_key = '1') then
                    ks_next_state <= S_KS_LOAD;
                end if;
        end case;
    end process;

    --------------------------------------------------------------------------
    -- FSM_PACKET state register (sequential)
    --------------------------------------------------------------------------
    p_PS_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                ps_state_reg <= S_PS_IDLE;
            else
                ps_state_reg <= ps_next_state;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM_PACKET next-state logic (combinational).
    -- IDLE -> RUN on EK push: marks "packet in flight" for the
    -- nonce-shadowing decision in p_DATA.
    -- RUN -> IDLE on w_flush_all (single-cycle, at tlast CT handshake).
    --------------------------------------------------------------------------
    p_PS_NEXT_STATE : process(ps_state_reg, r_ek_pushed, w_flush_all)
    begin
        ps_next_state <= ps_state_reg;
        case ps_state_reg is
            when S_PS_IDLE =>
                if r_ek_pushed = '1' then
                    ps_next_state <= S_PS_RUN;
                end if;

            when S_PS_RUN =>
                if w_flush_all = '1' then
                    ps_next_state <= S_PS_IDLE;
                end if;
        end case;
    end process;

    --------------------------------------------------------------------------
    -- w_flush_all: 1-cycle pulse on tlast CT handshake. Drives aes_enc_pipelined
    -- i_flush (clears r_valid_vector in one clock), and triggers shadow apply
    -- / IV-reuse guard in the same cycle.
    --------------------------------------------------------------------------
    w_flush_all <= '1' when (ps_state_reg     = S_PS_RUN
                              and w_pipe_out_handshake = '1'
                              and w_pipe_m_tuser       = c_TAG_CT
                              and s_axis_tlast         = '1'
                              and s_axis_tvalid        = '1'
                              and m_axis_tready        = '1')
                       else '0';

    --------------------------------------------------------------------------
    -- Apply-shadow pulses: fire on the w_flush_all cycle.
    --   Priority: shadow_key (forces full re-KE) > shadow_nonce (just new EK)
    --             > clean (IV-reuse guard).
    --------------------------------------------------------------------------

    w_apply_shadow_IV <= '1' when (w_flush_all = '1'
                                       and r_shadow_key_valid   = '0'
                                       and (r_shadow_IV_valid = '1' or i_nonce_valid = '1'))
                                else '0';
    -- Any key application on the flush cycle: a pending shadow key OR a key
    -- pulse coincident with the flush (promoted directly in p_DATA). Both
    -- restart KE, so both must bounce FSM_KEY and clear the H push/done flags.
    w_rekey_at_flush     <= '1' when (w_flush_all = '1'
                                       and (r_shadow_key_valid = '1'
                                            or i_key_valid     = '1'))
                                else '0';



    -- Side-band: pipeline-occupancy flag straight from the core
    o_encryption_in_proc <= w_pipe_in_proc;

end architecture;
