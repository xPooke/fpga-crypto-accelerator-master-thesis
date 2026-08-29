----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_gcm_enc_aes_keyrace
-- Module Name   : tb_gcm_enc_aes_keyrace - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Key-swap FREEZE reproducer for the GCM ENCRYPTOR (gcm_enc_glue +
--                 AES_algorithm). Fires a single i_key_valid pulse a swept number of
--                 cycles after the IV - offsets 1..4 used to wedge the H gate into a
--                 circular deadlock - and checks the system stays live.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;
use std.env.all;

entity tb_gcm_enc_aes_keyrace is
    generic (
        NUM_PKTS    : integer := 200;
        NUM_CORES   : integer := 4;
        G_KIND      : string  := "MULTICORE";  -- AES wrapper: MULTICORE | UNROLLED
        AAD_BEATS   : integer := 2;
        PT_BLOCKS   : integer := 4;        -- 64 B
        STRIDE      : integer := 1;
        N0          : integer := 0;
        SKEW_MAX    : integer := 7;        -- key_valid fired 0..SKEW_MAX cycles after o_H_valid
        COINCIDE    : boolean := true;     -- true: assert a key_valid burst mid-stream
        WARMUP_PKTS : integer := 1;        -- packets to run before arming the burst
        BURST_LEN   : integer := 1;        -- key_valid burst length in cycles (0 = forever)
        BURST_OFF   : integer := 2;        -- cycles after a packet's IV pulse to start the burst
        C_READY_PCT : integer := 100;
        C_TIMEOUT   : integer := 6000;
        TRACE       : boolean := false;    -- per-cycle internal probe (core + glue) after the burst arms
        INFILE      : string  := "data/inData.txt"
    );
end entity;

architecture tb of tb_gcm_enc_aes_keyrace is

    constant DATA_WIDTH : integer := 128;
    constant c_TKEEP_W  : integer := DATA_WIDTH/8;

    subtype slv128  is std_logic_vector(DATA_WIDTH-1 downto 0);
    subtype slv96   is std_logic_vector(95 downto 0);
    subtype slv256 is std_logic_vector(255 downto 0);

    constant NBLK_FILE : integer := 8;
    type blk_array is array(0 to NBLK_FILE-1) of slv128;

    constant c_NONCE_HI  : std_logic_vector(63 downto 0) := (others => '0');
    constant C_GLOBAL_TO : time := 80 ms;

    constant TOTAL_IN_BEATS  : integer := AAD_BEATS + PT_BLOCKS;
    constant TOTAL_OUT_BEATS : integer := AAD_BEATS + PT_BLOCKS + 1;

    function ivlo_of(n : integer)  return integer is begin return N0 + n*STRIDE; end;
    function ptidx_of(n, b : integer) return integer is begin return (n + b) mod NBLK_FILE; end;

    function iv_of(n : integer) return slv96 is
    begin
        return c_NONCE_HI & std_logic_vector(to_unsigned(ivlo_of(n), 32));
    end;

    -- Distinct key value per call index (guarantees a real key change so the
    -- core MUST recompute H; if it doesn't, the gate strands and we freeze).
    function key_of(idx : integer) return slv256 is
        variable v : slv256 := (others => '0');
    begin
        v(31 downto 0)  := std_logic_vector(to_unsigned(idx + 1, 32));
        v(63 downto 32) := std_logic_vector(to_unsigned(idx*5 + 3, 32));
        return v;
    end;

    signal clk           : std_logic := '0';
    signal rstn          : std_logic := '0';

    signal i_key         : slv256 := (others => '0');
    signal i_key_valid   : std_logic := '0';
    signal i_nonce          : slv96  := (others => '0');
    signal i_nonce_valid    : std_logic := '0';

    signal s_axis_tdata  : slv128 := (others => '0');
    signal s_axis_tkeep  : std_logic_vector(c_TKEEP_W-1 downto 0) := (others => '0');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tready : std_logic;

    signal m_axis_tdata  : slv128;
    signal m_axis_tkeep  : std_logic_vector(c_TKEEP_W-1 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tlast  : std_logic;
    signal m_axis_tready : std_logic := '1';

    signal o_ENC_in_proc : std_logic;
    signal o_TxENC       : std_logic_vector(31 downto 0);

    signal w_crypto_key       : slv256;
    signal w_crypto_key_valid : std_logic;
    signal w_crypto_IV        : slv96;
    signal w_crypto_IV_valid  : std_logic;

    signal w_pt_tdata    : slv128;
    signal w_pt_tkeep    : std_logic_vector(c_TKEEP_W-1 downto 0);
    signal w_pt_tvalid   : std_logic;
    signal w_pt_tlast    : std_logic;
    signal w_pt_tready   : std_logic;

    signal w_ct_tdata    : slv128;
    signal w_ct_tkeep    : std_logic_vector(c_TKEEP_W-1 downto 0);
    signal w_ct_tvalid   : std_logic;
    signal w_ct_tlast    : std_logic;
    signal w_ct_tready   : std_logic;

    signal w_H           : slv128;
    signal w_H_valid     : std_logic;
    signal w_E_k         : slv128;
    signal w_E_k_valid   : std_logic;
    signal w_h_stale     : std_logic;
    signal w_in_proc     : std_logic;

    signal files_loaded  : boolean := false;
    signal file_blocks   : blk_array := (others => (others => '0'));

    signal r_in_beats    : integer := 0;
    signal r_out_beats   : integer := 0;

    -- audit counters (key requests vs H responses)
    signal r_key_reqs    : integer := 0;
    signal r_h_resps     : integer := 0;

    signal r_iv_tick     : std_logic := '0';   -- p_stim pulses on each IV delivery

    -- key driving (decoupled so COINCIDE can add a combinational coincident term)
    signal r_kv_pulse    : std_logic := '0';   -- registered key pulse from p_keystress
    signal r_coincide    : std_logic := '0';   -- arm: i_key_valid follows w_H_valid
    signal r_key_value   : slv256 := (others => '0');

begin

    -- i_key_valid is r_kv_pulse OR (when armed) a sustained continuous assertion
    -- (models the "new key fires 1000x while it's wedged" symptom).
    i_key       <= r_key_value;
    i_key_valid <= r_kv_pulse or r_coincide;

    u_glue : entity work.gcm_enc_glue
        generic map (AAD_BEATS => AAD_BEATS, DATA_WIDTH => DATA_WIDTH)
        port map (
            i_clk => clk, i_rstn => rstn, i_tick => '0',
            i_key => i_key, i_key_valid => i_key_valid,
            i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,
            s_axis_tdata => s_axis_tdata, s_axis_tkeep => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid, s_axis_tlast => s_axis_tlast,
            s_axis_tready => s_axis_tready,
            m_axis_tdata => m_axis_tdata, m_axis_tkeep => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid, m_axis_tlast => m_axis_tlast,
            m_axis_tready => m_axis_tready,
            o_ENC_in_proc => o_ENC_in_proc, o_TxENC => o_TxENC,
            o_crypto_key => w_crypto_key, o_crypto_key_valid => w_crypto_key_valid,
            o_crypto_nonce => w_crypto_IV, o_crypto_nonce_valid => w_crypto_IV_valid,
            m_pt_axis_tdata => w_pt_tdata, m_pt_axis_tkeep => w_pt_tkeep,
            m_pt_axis_tvalid => w_pt_tvalid, m_pt_axis_tlast => w_pt_tlast,
            m_pt_axis_tready => w_pt_tready,
            s_ct_axis_tdata => w_ct_tdata, s_ct_axis_tkeep => w_ct_tkeep,
            s_ct_axis_tvalid => w_ct_tvalid, s_ct_axis_tlast => w_ct_tlast,
            s_ct_axis_tready => w_ct_tready,
            i_crypto_H => w_H, i_crypto_H_valid => w_H_valid,
            i_crypto_E_k => w_E_k, i_crypto_E_k_valid => w_E_k_valid,
            i_crypto_h_stale => w_h_stale,
            i_crypto_in_proc => w_in_proc
        );

    u_core : entity work.AES_algorithm
        generic map (AES_BITS => 128, ROUND_STYLE => "LUT", FLOW_STYLE => "GLOBAL",
                     WRAPPER_KIND => G_KIND, NUM_CORES => NUM_CORES)
        port map (
            i_clk => clk, i_rstn => rstn,
            i_key => w_crypto_key, i_key_valid => w_crypto_key_valid,
            i_nonce => w_crypto_IV, i_nonce_valid => w_crypto_IV_valid,
            s_axis_tdata => w_pt_tdata, s_axis_tvalid => w_pt_tvalid,
            s_axis_tready => w_pt_tready, s_axis_tlast => w_pt_tlast,
            s_axis_tkeep => w_pt_tkeep,
            m_axis_tdata => w_ct_tdata, m_axis_tvalid => w_ct_tvalid,
            m_axis_tready => w_ct_tready, m_axis_tlast => w_ct_tlast,
            m_axis_tkeep => w_ct_tkeep,
            o_H => w_H, o_H_valid => w_H_valid,
            o_E_k => w_E_k, o_E_k_valid => w_E_k_valid,
            o_h_stale => w_h_stale,
            o_encryption_in_proc => w_in_proc
        );

    clk  <= not clk after 5 ns;
    rstn <= '0', '1' after 53 ns;

    p_ready : process
        variable s1 : positive := 24;
        variable s2 : positive := 8675;
        variable r  : real;
    begin
        if C_READY_PCT >= 100 then
            m_axis_tready <= '1'; wait;
        else
            m_axis_tready <= '1';
            wait until rstn = '1';
            loop
                uniform(s1, s2, r);
                if (r * 100.0) < real(C_READY_PCT) then m_axis_tready <= '1';
                else m_axis_tready <= '0'; end if;
                wait until rising_edge(clk);
            end loop;
        end if;
    end process;

    p_load : process
        file     f   : text;
        variable st  : file_open_status;
        variable l   : line;
        variable v   : slv128;
    begin
        file_open(st, f, INFILE, read_mode);
        assert st = open_ok report "tb: cannot open " & INFILE severity failure;
        for i in 0 to NBLK_FILE-1 loop
            assert not endfile(f) report "tb: inData < 8 blocks" severity failure;
            readline(f, l); hread(l, v); file_blocks(i) <= v;
        end loop;
        file_close(f);
        files_loaded <= true;
        report "tb: loaded plaintext blocks" severity note;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- p_keystress : SOLE driver of i_key / i_key_valid.
    -- Delivers the initial key, then fires a fresh (distinct) key coincident
    -- with each o_H_valid, sweeping skew 0..SKEW_MAX cycles to walk the key
    -- swap onto the core's internal H-capture cycle.
    ----------------------------------------------------------------------------
    p_keystress : process
        variable idx  : integer := 1;
        variable skew : integer := 0;
        variable hpls : integer := 0;
        procedure fire(constant kidx : integer) is
        begin
            r_key_value <= key_of(kidx); r_kv_pulse <= '1';
            wait until rising_edge(clk);
            r_kv_pulse <= '0';
        end procedure;
    begin
        r_kv_pulse <= '0'; r_coincide <= '0';
        if not files_loaded then wait until files_loaded; end if;
        wait until rstn = '1';
        -- initial key for packet 0 (well before its IV)
        r_key_value <= key_of(0); r_kv_pulse <= '1';
        wait until rising_edge(clk);
        r_kv_pulse <= '0';

        if COINCIDE then
            -- Let the system warm up, then keep the key VALUE changing every
            -- cycle and arm the combinational coincident term so EVERY o_H_valid
            -- lands on an i_key_valid (the request+pulse the glue discards).
            -- If r_h_wait can never clear, the GHASH gate shuts -> freeze.
            wait until rising_edge(clk) and r_out_beats >= WARMUP_PKTS*TOTAL_OUT_BEATS;
            -- Align the burst to a packet's IV delivery, then offset by BURST_OFF
            -- cycles so the key event can be walked onto the core's IV-staging /
            -- flush / H-capture moment.
            wait until rising_edge(clk) and r_iv_tick = '1';
            for i in 1 to BURST_OFF loop wait until rising_edge(clk); end loop;
            r_coincide <= '1';
            hpls := 0;
            loop
                wait until rising_edge(clk);
                r_key_value <= key_of(idx);   -- free-running fresh key value
                idx := idx + 1;
                hpls := hpls + 1;
                -- Bounded burst: after BURST_LEN cycles drop key_valid and let
                -- the system try to recover. If it stays wedged, a transient key
                -- event permanently froze it (the real bug).
                if BURST_LEN > 0 and hpls >= BURST_LEN then
                    r_coincide <= '0';
                    wait;       -- stop poking; observe recovery / permanent freeze
                end if;
            end loop;
        else
            loop
                -- fire a real key change skew cycles after each H pulse
                wait until rising_edge(clk) and w_H_valid = '1';
                for s in 1 to skew loop wait until rising_edge(clk); end loop;
                fire(idx);
                idx  := idx + 1;
                skew := (skew + 1);
                if skew > SKEW_MAX then skew := 0; end if;
            end loop;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- p_stim : drives IV (time-driven, fresh per packet) + AXIS AAD||PT payload.
    ----------------------------------------------------------------------------
    p_stim : process
        procedure waitc(constant k : integer) is
        begin
            for i in 1 to k loop wait until rising_edge(clk); end loop;
        end procedure;

        procedure pulse_iv(constant ivv : slv96) is
        begin
            i_nonce <= ivv; i_nonce_valid <= '1'; r_iv_tick <= '1';
            wait until rising_edge(clk);
            i_nonce_valid <= '0'; r_iv_tick <= '0';
        end procedure;

        procedure send_beat(constant data : slv128;
                            constant last : boolean;
                            constant pkt  : integer;
                            constant tag  : string) is
            variable wd : integer := 0;
        begin
            s_axis_tdata  <= data;
            s_axis_tkeep  <= (others => '1');
            if last then s_axis_tlast <= '1'; else s_axis_tlast <= '0'; end if;
            s_axis_tvalid <= '1';
            loop
                wait until rising_edge(clk);
                exit when s_axis_tready = '1';
                wd := wd + 1;
                assert wd < C_TIMEOUT
                    report "tb: FREEZE - s_axis_tready stuck (key swap wedged GCM) pkt="
                         & integer'image(pkt) & " stage=" & tag severity failure;
            end loop;
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';
        end procedure;
    begin
        s_axis_tvalid <= '0'; s_axis_tlast <= '0';
        i_nonce_valid <= '0';
        if not files_loaded then wait until files_loaded; end if;
        wait until rstn = '1';
        waitc(4);   -- let the initial key settle

        for p in 0 to NUM_PKTS-1 loop
            pulse_iv(iv_of(p));
            for b in 0 to TOTAL_IN_BEATS-1 loop
                if b < AAD_BEATS then
                    send_beat(file_blocks(ptidx_of(p, b)), false, p, "AAD");
                else
                    send_beat(file_blocks(ptidx_of(p, b)), (b = TOTAL_IN_BEATS-1), p, "PT");
                end if;
            end loop;
        end loop;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Progress + audit counters
    ----------------------------------------------------------------------------
    p_progress : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '0' then
                r_in_beats <= 0; r_out_beats <= 0;
                r_key_reqs <= 0; r_h_resps <= 0;
            else
                if s_axis_tvalid = '1' and s_axis_tready = '1' then
                    r_in_beats <= r_in_beats + 1;
                end if;
                if m_axis_tvalid = '1' and m_axis_tready = '1' then
                    r_out_beats <= r_out_beats + 1;
                end if;
                if i_key_valid = '1' then r_key_reqs <= r_key_reqs + 1; end if;
                if w_H_valid   = '1' then r_h_resps  <= r_h_resps  + 1; end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Monitor / scoreboard
    ----------------------------------------------------------------------------
    p_mon : process
        variable out_pkt   : integer := 0;
        variable out_blk   : integer := 0;
        variable seen      : integer := 0;
        variable errc      : integer := 0;
        constant C_EXP_OUT : integer := NUM_PKTS * TOTAL_OUT_BEATS;
    begin
        wait until rstn = '1';
        loop
            wait until rising_edge(clk);
            if m_axis_tvalid = '1' and m_axis_tready = '1' then
                if is_x(m_axis_tdata) then
                    errc := errc + 1;
                    report "tb: X/U on m_axis_tdata out_pkt=" & integer'image(out_pkt)
                         & " beat=" & integer'image(out_blk) severity error;
                end if;
                out_blk := out_blk + 1;
                seen    := seen + 1;
                if m_axis_tlast = '1' then
                    if out_blk /= TOTAL_OUT_BEATS then
                        errc := errc + 1;
                        report "tb: OUTPUT BEAT COUNT MISMATCH pkt=" & integer'image(out_pkt)
                             & " got=" & integer'image(out_blk) severity error;
                    end if;
                    out_blk := 0;
                    out_pkt := out_pkt + 1;
                end if;

                if seen = C_EXP_OUT then
                    report "================ GCM-ENC KEYRACE SUMMARY ================" severity note;
                    report "  cores        = " & integer'image(NUM_CORES) severity note;
                    report "  out packets  = " & integer'image(out_pkt)
                         & " / " & integer'image(NUM_PKTS) severity note;
                    report "  out beats    = " & integer'image(seen)
                         & " / " & integer'image(C_EXP_OUT) severity note;
                    report "  key reqs     = " & integer'image(r_key_reqs) severity note;
                    report "  H responses  = " & integer'image(r_h_resps) severity note;
                    report "  errors       = " & integer'image(errc) severity note;
                    if out_pkt /= NUM_PKTS then
                        errc := errc + 1; report "tb: PACKET COUNT WRONG" severity error;
                    end if;
                    if errc = 0 then report "RESULT: PASS" severity note;
                    else report "RESULT: FAIL (" & integer'image(errc) & " errors)" severity failure;
                    end if;
                    report "========================================================" severity note;
                    finish;
                end if;
            end if;
        end loop;
    end process;

    ----------------------------------------------------------------------------
    -- Output forward-progress freeze watchdog
    ----------------------------------------------------------------------------
    p_freeze : process
        variable last_in  : integer := -1;
        variable last_out : integer := -1;
        variable stuck    : integer := 0;
    begin
        wait until rstn = '1';
        loop
            wait until rising_edge(clk);
            if (r_in_beats = last_in) and (r_out_beats = last_out) then
                stuck := stuck + 1;
                if stuck >= C_TIMEOUT then
                    report "tb: FREEZE - no AXIS progress for " & integer'image(C_TIMEOUT)
                         & " cycles (in=" & integer'image(r_in_beats)
                         & " out=" & integer'image(r_out_beats)
                         & " key_reqs=" & integer'image(r_key_reqs)
                         & " H_resps=" & integer'image(r_h_resps)
                         & "): GCM wedged by key swap" severity failure;
                end if;
            else
                stuck := 0;
            end if;
            last_in  := r_in_beats;
            last_out := r_out_beats;
        end loop;
    end process;

    p_watchdog : process
    begin
        wait for C_GLOBAL_TO;
        report "tb: GLOBAL TIMEOUT - did not finish (deadlock?)" severity failure;
    end process;

    ----------------------------------------------------------------------------
    -- ANALYSIS probe (observe-only): per-cycle trace of the CORE and GLUE
    -- internals once the burst is armed, so the stuck state at the freeze is
    -- visible in the tail of the log. External names do not modify the DUT.
    ----------------------------------------------------------------------------
    gen_trace : if TRACE generate
        p_trace : process(clk)
            alias c_haveN  is << signal .tb_gcm_enc_aes_keyrace.u_core.gen_unrolled.u_aes.r_have_nonce        : std_logic >>;
            alias c_keNew  is << signal .tb_gcm_enc_aes_keyrace.u_core.gen_unrolled.u_aes.r_ke_new_key        : std_logic >>;
            alias c_hRec   is << signal .tb_gcm_enc_aes_keyrace.u_core.gen_unrolled.u_aes.r_h_pushed : std_logic >>;
            alias c_hDone  is << signal .tb_gcm_enc_aes_keyrace.u_core.gen_unrolled.u_aes.r_h_done            : std_logic >>;
            alias c_shIVv  is << signal .tb_gcm_enc_aes_keyrace.u_core.gen_unrolled.u_aes.r_shadow_IV_valid   : std_logic >>;
            alias c_shKEYv is << signal .tb_gcm_enc_aes_keyrace.u_core.gen_unrolled.u_aes.r_shadow_key_valid  : std_logic >>;
            alias g_hWait  is << signal .tb_gcm_enc_aes_keyrace.u_glue.w_h_stale           : std_logic >>;
            alias g_inPkt  is << signal .tb_gcm_enc_aes_keyrace.u_glue.r_gh_in_pkt         : std_logic >>;
            -- GHASH ingress-latency probes
            alias g_sbv    is << signal .tb_gcm_enc_aes_keyrace.u_glue.w_sb_tvalid         : std_logic >>;
            alias g_sbr    is << signal .tb_gcm_enc_aes_keyrace.u_glue.w_sb_tready         : std_logic >>;
            alias gh_corev is << signal .tb_gcm_enc_aes_keyrace.u_glue.u_ghash.w_core_valid : std_logic >>;
            variable l : line;
            function sb(s : std_logic) return string is
            begin if s = '1' then return "1"; else return "0"; end if; end;
        begin
            if rising_edge(clk) and rstn = '1' and r_out_beats >= WARMUP_PKTS*TOTAL_OUT_BEATS then
                write(l, string'("TR IVv=")); write(l, sb(i_nonce_valid));
                write(l, string'(" KEYv=")); write(l, sb(i_key_valid));
                write(l, string'(" sTV=")); write(l, sb(s_axis_tvalid));
                write(l, string'(" sRdy=")); write(l, sb(s_axis_tready));
                write(l, string'(" |C haveN=")); write(l, sb(c_haveN));
                write(l, string'(" keNew=")); write(l, sb(c_keNew));
                write(l, string'(" hDone=")); write(l, sb(c_hDone));
                write(l, string'(" hRec=")); write(l, sb(c_hRec));
                write(l, string'(" shKEYv=")); write(l, sb(c_shKEYv));
                write(l, string'(" Hv=")); write(l, sb(w_H_valid));
                write(l, string'(" |G hWait=")); write(l, sb(g_hWait));
                write(l, string'(" inPkt=")); write(l, sb(g_inPkt));
                write(l, string'(" ghCoreV=")); write(l, sb(gh_corev));
                writeline(output, l);
            end if;
        end process;
    end generate;

end architecture;
