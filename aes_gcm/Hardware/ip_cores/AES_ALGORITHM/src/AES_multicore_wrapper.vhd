----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : May 2026
-- Design Name   : AES_multicore_wrapper
-- Module Name   : AES_multicore_wrapper - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : GCM-mode AES crypto wrapper. NUM_CORES rolled cores
--                 (aes_enc_rolled) in round-robin; one shared KE
--                 runs on-the-fly in lockstep with the cores so dispatch
--                 begins immediately after i_key_valid (no global
--                 keys-ready handshake). Per packet: H = AES_K(0),
--                 EK = AES_K(J0), then CT_i = PT_i XOR AES_K(J0+i).
--                 Round keys K_1..K_NR are delivered as a write stream
--                 (one key per clock out of the KE) broadcast to a local
--                 distributed-RAM copy inside every core; K_0 is wired
--                 statically. The stream lands on the same clock edge as
--                 the KE's own registers, so the on-the-fly lockstep
--                 holds and a core may start on any cycle.
--                 Main rounds (1..NR-1) inside each core use BRAM
--                 T-tables or LUT functions per ROUND_STYLE; the last
--                 round is always inline LUT (no MixColumns means no
--                 T-table benefit). Mid-packet shadow key + nonce apply
--                 at packet boundary. AES-128 and AES-256 supported.
--
-- Dependencies  : work.aes_pkg, work.KeyExpansion, work.aes_enc_rolled
--
-- Revision      :
--   0.01 - May 2026 - File Created
--   0.02 - Aug 2026 - Round keys as per-core distributed-RAM copies fed by
--                     the key-expansion write stream; core selection as
--                     event-driven one-hot enables. Cycle-identical, about
--                     a quarter fewer LUTs
--
-- Additional Comments :
--   Active-low reset (i_rstn). w_flush_all is a 1-cycle end-of-packet
--   pulse driven on tlast handshake; clears EK + counters + r_ctr32 in
--   the wrapper and r_valid_vector in every core (via i_flush_all).
--   IV-reuse guard: r_have_nonce clears on flush unless r_shadow_IV
--   was staged during the packet.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.aes_pkg.all;

entity AES_multicore_wrapper is
    generic (
        AES_BITS    : integer := 128;       -- 128 or 256
        ROUND_STYLE : string  := "BRAM";    -- "BRAM" or "LUT" (passed to aes_round)
        NUM_CORES   : integer := 4          -- parallel rolled cores
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;       -- active low

        -- Key + nonce config. i_key is the 256-bit caller-side key; the LSB
        -- AES_BITS bits are used internally as the AES key (the rest is
        -- ignored). i_nonce is the 96-bit GCM nonce; J0 = nonce || 0^31 || 1
        -- is formed here, so the counter block can never be malformed by the
        -- caller.
        i_key         : in  std_logic_vector(255 downto 0);
        i_key_valid   : in  std_logic;
        i_nonce       : in  std_logic_vector(95 downto 0);
        i_nonce_valid : in  std_logic;

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

        -- E_K(J0) output (tag mask for tag generator)
        o_E_k         : out std_logic_vector(127 downto 0);
        o_E_k_valid   : out std_logic;

        -- Side-band: '1' while the latched H is stale -- a key change is pending
        -- its recompute, so H = E_K(0) is not yet valid for the next packet.
        -- A downstream GHASH gate holds a packet's first beat while this is high.
        o_h_stale     : out std_logic;

        -- Side-band: '1' while any core is mid-round (registered OR)
        o_encryption_in_proc : out std_logic
    );
end entity;

architecture rtl of AES_multicore_wrapper is

    ----------------------------------------------------------------------------
    -- Helpers
    ----------------------------------------------------------------------------
    function log2_ceil(n : integer) return integer is
        variable i : integer := 1;
        variable v : integer := 2;
    begin
        if n <= 1 then return 1; end if;
        while v < n loop
            i := i + 1;
            v := v * 2;
        end loop;
        return i;
    end function;

    function dispatch_delay_for(bits : integer) return integer is
    begin
        if bits = 256 then return 0; else return 1; end if;
    end function;

    constant NUM_CORES_BITS   : integer := log2_ceil(NUM_CORES);  -- local log2_ceil returns >= 1, so NUM_CORES = 1 stays a real vector
    -- Cycles to wait between r_ke_new_key and the first start_enc so the
    -- core reads K_0+K_1 the cycle they become valid out of the KE.
    --   AES-256 = 0 (K_0 and K_1 both valid in cycle 2 from LOAD)
    --   AES-128 = 1 (K_1 valid only in cycle 3 after EXPAND cycle 1)
    constant c_DISPATCH_DELAY : integer := dispatch_delay_for(AES_BITS);

    ----------------------------------------------------------------------------
    -- KeyExpansion interface
    ----------------------------------------------------------------------------
    signal r_active_key : std_logic_vector(AES_BITS-1 downto 0) := (others => '0');  -- latched active key
    signal w_padded_key : std_logic_vector(255 downto 0);                            -- r_active_key padded to 256b for KE port
    signal r_ke_new_key : std_logic := '0';                                          -- 1-cycle pulse to KE on new key
    signal w_round_keys : arr_round_keys_t;                                          -- KE output: K_0 .. K_NR

    -- Round-key write stream (KE -> every core's distributed-RAM copy)
    signal w_rk_wr_en   : std_logic;
    signal w_rk_wr_addr : unsigned(3 downto 0);
    signal w_rk_wr_data : std_logic_vector(127 downto 0);

    ----------------------------------------------------------------------------
    -- Dispatch-enable gating (aligns first start_enc with KE round-key timing)
    ----------------------------------------------------------------------------
    signal r_dispatch_count  : integer range 0 to 1 := 1;   -- countdown from c_DISPATCH_DELAY after r_ke_new_key
    signal r_have_key        : std_logic := '0';            -- '1' once first key has been latched
    signal w_dispatch_enable : std_logic;                   -- start_enc gate (high once KE round keys are tracking the cores)

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_RUN);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Role-dispatch tracking
    ----------------------------------------------------------------------------
    signal r_h_dispatched      : std_logic := '0';   -- H start_enc has fired for current key
    signal r_ek_dispatched     : std_logic := '0';   -- EK start_enc has fired for current packet
    signal r_h_done            : std_logic := '0';   -- H output captured into r_H
    signal r_ek_done           : std_logic := '0';   -- EK output captured into r_E_k
    signal r_h_needs_recompute : std_logic := '1';   -- key changed since last H capture; forces H re-dispatch
    signal w_flush_all         : std_logic;          -- 1-cycle end-of-packet pulse (tlast handshake)

    ----------------------------------------------------------------------------
    -- Nonce + GCM counter (NIST SP 800-38D)
    ----------------------------------------------------------------------------
    -- 128-bit IV: high 96 bits stay locked (caller's "nonce" portion); low
    -- 32 bits are the counter portion, incremented on every EK or CT dispatch.
    signal w_J0         : std_logic_vector(127 downto 0);                    -- J0 = i_nonce || 0^31 || 1
    signal r_nonce      : std_logic_vector(127 downto 0) := (others => '0');
    signal r_have_nonce : std_logic := '0';                                  -- '1' when r_nonce is fresh (IV-reuse guard clears at packet end)

    -- Shared crypto-core input mux: drives every core's i_plaintext; only the
    -- core whose start_enc is '1' this cycle actually latches it.
    signal w_crypto_input : std_logic_vector(127 downto 0);

    ----------------------------------------------------------------------------
    -- Shadow registers (apply at packet boundary if input arrived during S_RUN)
    ----------------------------------------------------------------------------
    signal r_shadow_key         : std_logic_vector(AES_BITS-1 downto 0) := (others => '0');  -- pending key
    signal r_shadow_key_valid   : std_logic := '0';                                          -- pending key flag
    signal r_shadow_IV       : std_logic_vector(127 downto 0) := (others => '0');  -- pending IV
    signal r_shadow_IV_valid : std_logic := '0';                                   -- pending IV flag

    ----------------------------------------------------------------------------
    -- Round-robin selection: rotating one-hot enables, shifted on the event
    -- they gate. A binary shadow counter steps with r_out_onehot and serves
    -- only as the select of the 128-bit result mux.
    ----------------------------------------------------------------------------
    signal r_start_onehot   : std_logic_vector(0 to NUM_CORES-1) := (0 => '1', others => '0');  -- next core to receive start_enc
    signal r_out_onehot     : std_logic_vector(0 to NUM_CORES-1) := (0 => '1', others => '0');  -- next core whose output is released
    signal r_counter_output : unsigned(NUM_CORES_BITS-1 downto 0) := (others => '0');           -- binary shadow of r_out_onehot (result mux only)

    signal w_start_sel_ready : std_logic;  -- selected core's ready flag (OR over one-hot AND ready)
    signal w_start_fire      : std_logic;  -- this cycle's dispatch strobe (at most one core)
    signal w_out_sel_done    : std_logic;  -- selected core's done flag (OR over one-hot AND done)
    signal w_release_fire    : std_logic;  -- this cycle's release strobe (at most one core)

    ----------------------------------------------------------------------------
    -- Per-core wire arrays (one element per core)
    ----------------------------------------------------------------------------
    type sl_array_t   is array (natural range <>) of std_logic;
    type sl_array_t_2 is array (natural range <>) of std_logic_vector(127 downto 0);

    signal arr_w_encryption_done    : sl_array_t(0 to NUM_CORES-1);    -- core has finished current block
    signal arr_w_encryption_ready   : sl_array_t(0 to NUM_CORES-1);    -- core can accept new start_enc
    signal arr_w_encryption_in_proc : sl_array_t(0 to NUM_CORES-1);    -- core currently mid-round

    -- Registered OR of every core's in-proc flag (drives o_encryption_in_proc)
    signal r_encryption_in_proc : std_logic := '0';
    signal arr_w_start_enc          : sl_array_t(0 to NUM_CORES-1);    -- per-core start pulse (at most 1-hot per cycle)
    signal arr_w_valid              : sl_array_t(0 to NUM_CORES-1);    -- per-core release pulse (at most 1-hot per cycle)
    signal arr_w_cipher_text        : sl_array_t_2(0 to NUM_CORES-1);  -- per-core 128-bit result

    ----------------------------------------------------------------------------
    -- Side-band outputs (H, EK) buffered with a 1-cycle valid pulse
    ----------------------------------------------------------------------------
    signal r_H         : std_logic_vector(127 downto 0) := (others => '0');  -- captured H = AES_K(0)
    signal r_H_pulse   : std_logic := '0';                                   -- 1-cycle valid on H capture
    signal r_E_k       : std_logic_vector(127 downto 0) := (others => '0');  -- captured EK = AES_K(J0)
    signal r_E_k_pulse : std_logic := '0';                                   -- 1-cycle valid on EK capture

    ----------------------------------------------------------------------------
    -- Output mux helpers
    ----------------------------------------------------------------------------
    signal w_cipher_out    : std_logic_vector(127 downto 0);  -- arr_w_cipher_text(r_counter_output)
    signal w_m_axis_tvalid : std_logic;                       -- internal copy of m_axis_tvalid (also feeds tlast / flush logic)
    signal w_out_is_ct     : std_logic;                       -- '1' once both H and EK are captured (next outputs are CT)

begin

    --------------------------------------------------------------------------
    -- Generic validation
    --------------------------------------------------------------------------
    assert (AES_BITS = 128) or (AES_BITS = 256)
        report "AES_multicore_wrapper: AES_BITS must be 128 or 256"
        severity failure;
    assert NUM_CORES >= 1
        report "AES_multicore_wrapper: NUM_CORES must be >= 1"
        severity failure;

    --------------------------------------------------------------------------
    -- J0 for a 96-bit nonce: nonce || 0^31 || 1 (NIST SP 800-38D)
    --------------------------------------------------------------------------
    w_J0 <= i_nonce & x"00000001";

    --------------------------------------------------------------------------
    -- Pad i_key to 256 bits for KeyExpansion (AES-128 in upper 128 bits)
    --------------------------------------------------------------------------
    gen_pad_128 : if AES_BITS = 128 generate
        w_padded_key <= r_active_key & x"00000000000000000000000000000000";
    end generate;
    gen_pad_256 : if AES_BITS = 256 generate
        w_padded_key <= r_active_key;
    end generate;

    --------------------------------------------------------------------------
    -- KeyExpansion
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
            o_round_keys => w_round_keys,
            o_rk_wr_en   => w_rk_wr_en,
            o_rk_wr_addr => w_rk_wr_addr,
            o_rk_wr_data => w_rk_wr_data
        );

    --------------------------------------------------------------------------
    -- Generate NUM_CORES rolled crypto cores. Round keys arrive through the
    -- broadcast write stream into each core's local distributed-RAM copy on
    -- the same clock edge the KE registers them, so the on-the-fly lockstep
    -- (K_i readable when a core's counter reaches i-1) is exactly the old
    -- shared-array behavior. K_0 is a constant-index wire.
    --------------------------------------------------------------------------
    gen_cores : for i in 0 to NUM_CORES-1 generate
        u_core : entity work.aes_enc_rolled
            generic map (
                AES_BITS    => AES_BITS,
                ROUND_STYLE => ROUND_STYLE
            )
            port map (
                i_clk                => i_clk,
                i_rstn               => i_rstn,
                i_plaintext          => w_crypto_input,
                i_start_enc          => arr_w_start_enc(i),
                o_encryption_done    => arr_w_encryption_done(i),
                o_encryption_ready   => arr_w_encryption_ready(i),
                o_encryption_in_proc => arr_w_encryption_in_proc(i),
                o_cipher_text        => arr_w_cipher_text(i),
                i_key0               => w_round_keys(0),
                i_rk_wr_en           => w_rk_wr_en,
                i_rk_wr_addr         => w_rk_wr_addr,
                i_rk_wr_data         => w_rk_wr_data,
                i_block_consumed     => arr_w_valid(i),
                i_flush_all          => w_flush_all
            );
    end generate gen_cores;

    --------------------------------------------------------------------------
    -- Dispatch-enable counter
    --------------------------------------------------------------------------
    p_DISPATCH_ENABLE : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_dispatch_count <= 1;
                r_have_key       <= '0';
            elsif r_ke_new_key = '1' then
                r_dispatch_count <= c_DISPATCH_DELAY;
                r_have_key       <= '1';
            elsif r_dispatch_count > 0 then
                r_dispatch_count <= r_dispatch_count - 1;
            end if;
        end if;
    end process;

    w_dispatch_enable <= '1' when r_have_key = '1' and r_dispatch_count = 0
                             else '0';

    --------------------------------------------------------------------------
    -- Crypto-core input mux. Shared across all cores; only the core(s) with
    -- start_enc='1' this cycle latch it.
    --   r_h_dispatched='0'                        -> 0^128 (H input)
    --   else                                       -> r_nonce (full 128-bit IV,
    --                                                 low 32 bits already
    --                                                 reflect EK/CT increments)
    --
    -- r_h_needs_recompute gates the H branch: when '0' (H already done for
    -- this key), the mux skips H and starts with EK.
    --------------------------------------------------------------------------
    w_crypto_input <=
        (others => '0') when r_h_needs_recompute = '1' and r_h_dispatched = '0'
        else r_nonce;

    --------------------------------------------------------------------------
    -- Per-core release strobe (drives each core's i_block_consumed).
    -- A core's output is released only when arr_w_valid[i]='1'. We release
    -- the core pointed to by r_counter_output once its result is done and:
    --   * H/EK capture: release unconditionally (no PT XOR happens)
    --   * CT output:    release only when PT is present AND downstream ready
    --                   (so the AXIS handshake is consummated).
    --------------------------------------------------------------------------
    -- Selected core's done flag: OR over (one-hot AND done), no index decode.
    p_OUT_SEL : process(r_out_onehot, arr_w_encryption_done)
        variable v_or : std_logic;
    begin
        v_or := '0';
        for i in 0 to NUM_CORES-1 loop
            v_or := v_or or (r_out_onehot(i) and arr_w_encryption_done(i));
        end loop;
        w_out_sel_done <= v_or;
    end process;

    -- Release strobe: same condition as before (done AND, for CT, the full
    -- AXIS handshake), steered to the selected core by the one-hot.
    w_release_fire <= '1' when w_out_sel_done = '1'
                           and (w_out_is_ct = '0'
                                or (s_axis_tvalid = '1' and m_axis_tready = '1'))
                      else '0';

    gen_valid : for i in 0 to NUM_CORES-1 generate
        arr_w_valid(i) <= r_out_onehot(i) and w_release_fire;
    end generate gen_valid;

    --------------------------------------------------------------------------
    -- "What's the output type right now" — based on capture flags.
    --   r_h_done='0'  -> next completion will be H
    --   r_ek_done='0' -> next completion will be EK
    --   else          -> CT
    --------------------------------------------------------------------------
    w_out_is_ct <= '1' when r_h_done = '1' and r_ek_done = '1' else '0';

    --------------------------------------------------------------------------
    -- Per-core "start_enc": fire when wrapper is in S_RUN AND the selected
    -- core is ready AND dispatch-enable is on.
    --
    -- CT keystream is dispatched EAGERLY (no s_axis_tvalid gate). Cores
    -- compute keystream as soon as they're free; PT/CT availability is only
    -- checked at OUTPUT (release via w_release_fire). Eager dispatch is
    -- bounded by NUM_CORES in flight; any unused keystream at packet end
    -- is discarded by w_flush_all. Dispatch must not wait on s_axis_tvalid:
    -- in the decryption path s_axis_tready itself depends on a keystream
    -- being ready, so the keystream has to come first.
    --------------------------------------------------------------------------
    -- Selected core's ready flag: OR over (one-hot AND ready), no index decode.
    p_START_SEL : process(r_start_onehot, arr_w_encryption_ready)
        variable v_or : std_logic;
    begin
        v_or := '0';
        for i in 0 to NUM_CORES-1 loop
            v_or := v_or or (r_start_onehot(i) and arr_w_encryption_ready(i));
        end loop;
        w_start_sel_ready <= v_or;
    end process;

    -- The role condition does not depend on the selected core; the one-hot
    -- only steers the strobe.
    -- r_ke_new_key = '0': no dispatch in the cycle a new key applies
    -- (S_IDLE re-key race; reproducer: tb_key_idle_race).
    w_start_fire <= '1' when state_reg = S_RUN and w_dispatch_enable = '1'
                         and r_ke_new_key = '0'
                         and w_start_sel_ready = '1'
                         and (   (r_h_needs_recompute = '1' and r_h_dispatched = '0')
                              or (r_ek_dispatched = '0' and r_have_nonce = '1')
                              or (r_h_dispatched = '1' and r_ek_dispatched = '1'))
                    else '0';

    gen_start : for i in 0 to NUM_CORES-1 generate
        arr_w_start_enc(i) <= r_start_onehot(i) and w_start_fire;
    end generate gen_start;

    --------------------------------------------------------------------------
    -- Dispatch-flag tracking. Set when a start_enc fires for the respective
    -- role; cleared on flush (packet boundary) or new-key pulse.
    -- The 32-bit counter portion of r_nonce advances on EK or CT dispatch.
    --------------------------------------------------------------------------
    p_DISPATCH_FLAGS : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_h_dispatched  <= '0';
                r_ek_dispatched <= '0';
            elsif w_flush_all = '1' or r_ke_new_key = '1' then
                -- End of packet OR new key staged: clear EK so next packet
                -- re-dispatches EK. H is cleared only on new-key (handled
                -- below — r_h_dispatched stays '1' across packets unless key
                -- changes, so r_h_needs_recompute drives the H gating).
                r_ek_dispatched <= '0';
                if r_ke_new_key = '1' then
                    r_h_dispatched <= '0';
                end if;
            elsif w_start_fire = '1' then
                if r_h_needs_recompute = '1' and r_h_dispatched = '0' then
                    r_h_dispatched <= '1';
                elsif r_ek_dispatched = '0' and r_have_nonce = '1' then
                    r_ek_dispatched <= '1';
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Start one-hot: rotates by one position on each successful start_enc
    -- (the event it gates), back to core 0 on reset / flush.
    --------------------------------------------------------------------------
    p_START_ONEHOT : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' or w_flush_all = '1' then
                r_start_onehot    <= (others => '0');
                r_start_onehot(0) <= '1';
            elsif w_start_fire = '1' then
                r_start_onehot <= r_start_onehot(NUM_CORES-1)
                                  & r_start_onehot(0 to NUM_CORES-2);
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Output one-hot + binary shadow: both rotate on each successful release
    -- (arr_w_valid pulse), so they stay in lockstep by construction. The
    -- shadow exists only for the 128-bit result mux.
    --------------------------------------------------------------------------
    p_OUT_ONEHOT : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' or w_flush_all = '1' then
                r_out_onehot     <= (others => '0');
                r_out_onehot(0)  <= '1';
                r_counter_output <= (others => '0');
            elsif w_release_fire = '1' then
                r_out_onehot <= r_out_onehot(NUM_CORES-1)
                                & r_out_onehot(0 to NUM_CORES-2);
                if r_counter_output = to_unsigned(NUM_CORES-1, NUM_CORES_BITS) then
                    r_counter_output <= (others => '0');
                else
                    r_counter_output <= r_counter_output + 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Nonce + shadow-key + shadow-nonce latching
    --------------------------------------------------------------------------
    -- Branch priority (highest first):
    --   1. flush      -> shadow apply or clear r_have_nonce
    --   2. i_nonce_valid -> direct latch (S_IDLE) or stage shadow (S_RUN)
    --   3. EK/CT start_enc -> low-32 counter increment
    p_INPUTS : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_active_key         <= (others => '0');
                r_nonce              <= (others => '0');
                r_have_nonce         <= '0';
                r_ke_new_key         <= '0';
                r_shadow_key         <= (others => '0');
                r_shadow_key_valid   <= '0';
                r_shadow_IV       <= (others => '0');
                r_shadow_IV_valid <= '0';
            else
                r_ke_new_key <= '0';

                -- Key mutation: mutually exclusive priorities. Invariant: a
                -- key pulse on the flush cycle is never dropped -- it either
                -- applies directly, or (latest-wins) overrides any shadow staged for
                -- the packet after (the shadow applies this cycle). Only the
                -- LSB AES_BITS bits of i_key are used.
                if w_flush_all = '1' and state_reg = S_RUN then
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
                    if state_reg = S_RUN then
                        r_shadow_key       <= i_key(AES_BITS-1 downto 0);
                        r_shadow_key_valid <= '1';
                    else
                        r_active_key <= i_key(AES_BITS-1 downto 0);
                        r_ke_new_key <= '1';
                    end if;
                end if;

                -- r_nonce mutation: mutually exclusive priorities.
                if w_flush_all = '1' and state_reg = S_RUN then
                    -- Resolve the successor packet's IV. Invariant: an
                    -- i_nonce_valid pulse on the flush cycle is never dropped --
                    -- it either applies directly (latest-wins over any shadow), same as
                    -- the key chain.
                    if r_shadow_IV_valid = '1' then
                        r_nonce      <= r_shadow_IV;
                        r_have_nonce <= '1';
                        if i_nonce_valid = '1' then
                            -- Latest-wins: a fresh IV on the flush cycle overrides any staged shadow.
                            r_nonce       <= w_J0;
                            r_have_nonce <= '1';
                        end if;
                        r_shadow_IV_valid <= '0';

                    elsif i_nonce_valid = '1' then
                        -- IV arriving on the flush cycle with no prior shadow:
                        -- apply it directly so the next packet can start.
                        r_nonce      <= w_J0;
                        r_have_nonce <= '1';
                    else
                        -- No shadow nonce: clear r_have_nonce so next packet
                        -- must explicitly pulse i_nonce_valid (IV-reuse guard).
                        r_have_nonce <= '0';
                    end if;
                else
                    if i_nonce_valid = '1' then
                        if state_reg = S_RUN then
                            r_shadow_IV       <= w_J0;
                            r_shadow_IV_valid <= '1';
                        else
                            r_nonce      <= w_J0;
                            r_have_nonce <= '1';
                        end if;
                    end if;
                    -- EK or CT dispatch: advance low-32 counter portion.
                    -- Independent of the IV capture above: a mid-packet
                    -- i_nonce_valid writes only the shadow register while the
                    -- in-flight packet's counter still advances. In S_IDLE
                    -- no start_enc fires, so the direct IV latch and the
                    -- increment are mutually exclusive.
                    if w_start_fire = '1'
                       and not (r_h_needs_recompute = '1' and r_h_dispatched = '0') then
                        r_nonce(31 downto 0) <=
                            std_logic_vector(unsigned(r_nonce(31 downto 0)) + 1);
                    end if;
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
                state_reg <= S_IDLE;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM next-state + flush pulse
    --------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, r_have_key, r_have_nonce,
                           s_axis_tlast, s_axis_tvalid,
                           m_axis_tready, w_m_axis_tvalid)
    begin
        next_state  <= state_reg;
        w_flush_all <= '0';
        case state_reg is
            when S_IDLE =>
                -- Enter S_RUN once we have a key (KE running) and a nonce.
                -- Dispatch enable will further gate the actual start_enc.
                if r_have_key = '1' and r_have_nonce = '1' then
                    next_state <= S_RUN;
                end if;

            when S_RUN =>
                -- End of packet on tlast handshake (CT path).
                if s_axis_tlast = '1'
                   and m_axis_tready = '1'
                   and w_m_axis_tvalid = '1' then
                    w_flush_all <= '1';
                    next_state  <= S_IDLE;
                end if;
        end case;
    end process;

    --------------------------------------------------------------------------
    -- H capture: first completion (when r_h_done='0') goes to r_H.
    -- Updates r_h_needs_recompute: SET on new-key pulse, CLEAR on capture.
    --------------------------------------------------------------------------
    p_H : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_H                 <= (others => '0');
                r_H_pulse           <= '0';
                r_h_done            <= '0';
                r_h_needs_recompute <= '1';
            else
                r_H_pulse <= '0';

                if r_ke_new_key = '1' then
                    r_h_done            <= '0';
                    r_h_needs_recompute <= '1';
                end if;

                -- w_release_fire implies done AND valid of the selected core;
                -- w_cipher_out is that core's result (shared binary mux).
                if r_h_done = '0' and r_h_needs_recompute = '1'
                   and w_release_fire = '1' then
                    r_H                 <= w_cipher_out;
                    r_H_pulse           <= '1';
                    r_h_done            <= '1';
                    r_h_needs_recompute <= '0';
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- EK capture: completion after H is captured (or after a packet without
    -- key change) goes to r_E_k. r_ek_done clears on flush so next packet
    -- captures a fresh EK.
    --------------------------------------------------------------------------
    p_EK : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_E_k       <= (others => '0');
                r_E_k_pulse <= '0';
                r_ek_done   <= '0';
            else
                r_E_k_pulse <= '0';

                if w_flush_all = '1' or r_ke_new_key = '1' then
                    r_ek_done <= '0';
                end if;

                if r_ek_done = '0' and r_h_done = '1'
                   and r_h_needs_recompute = '0'
                   and w_release_fire = '1' then
                    r_E_k       <= w_cipher_out;
                    r_E_k_pulse <= '1';
                    r_ek_done   <= '1';
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- AXIS output (CT path).
    -- CT is presented only when r_h_done='1' AND r_ek_done='1' (both captured)
    -- AND the current output core has its result ready AND PT is present.
    --------------------------------------------------------------------------
    -- Result mux stays on the binary shadow counter (see the selection
    -- comment above); the done qualifier comes from the one-hot control path.
    w_cipher_out <= arr_w_cipher_text(to_integer(r_counter_output));

    w_m_axis_tvalid <= '1' when state_reg = S_RUN
                            and w_out_is_ct = '1'
                            and w_out_sel_done = '1'
                            and s_axis_tvalid = '1'
                       else '0';

    s_axis_tready <= '1' when state_reg = S_RUN
                          and w_out_is_ct = '1'
                          and w_out_sel_done = '1'
                          and m_axis_tready = '1'
                     else '0';

    m_axis_tvalid <= w_m_axis_tvalid;
    m_axis_tdata  <= w_cipher_out xor s_axis_tdata;
    m_axis_tlast  <= s_axis_tlast;
    m_axis_tkeep  <= s_axis_tkeep;

    --------------------------------------------------------------------------
    -- Side-band outputs
    --------------------------------------------------------------------------
    o_H         <= r_H;
    o_H_valid   <= r_H_pulse;
    o_E_k       <= r_E_k;
    o_E_k_valid <= r_E_k_pulse;

    -- High whenever the latched H no longer matches the active key: set on a
    -- new-key pulse, cleared when H is recaptured.
    o_h_stale   <= r_h_needs_recompute;

    --------------------------------------------------------------------------
    -- "Diode" indicator: registered OR of every core's in-proc flag.
    --------------------------------------------------------------------------
    p_DIODE : process(i_clk)
        variable v_or : std_logic;
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_encryption_in_proc <= '0';
            else
                v_or := '0';
                for i in 0 to NUM_CORES-1 loop
                    v_or := v_or or arr_w_encryption_in_proc(i);
                end loop;
                r_encryption_in_proc <= v_or;
            end if;
        end if;
    end process p_DIODE;

    o_encryption_in_proc <= r_encryption_in_proc;

end architecture;
