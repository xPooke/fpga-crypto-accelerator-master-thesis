----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_gcm_dec_aes_keyrace
-- Module Name   : tb_gcm_dec_aes_keyrace - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Key-swap FREEZE reproducer for the GCM DECRYPTOR (gcm_dec_glue +
--                 AES_algorithm), mirroring tb_gcm_enc_aes_keyrace. Liveness-only: a
--                 frozen H gate stalls s_axis_tready and the output, which the
--                 watchdogs catch.
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

entity tb_gcm_dec_aes_keyrace is
    generic (
        NUM_PKTS    : integer := 60;
        NUM_CORES   : integer := 4;
        G_KIND      : string  := "MULTICORE";  -- AES wrapper: MULTICORE | UNROLLED
        AAD_BEATS   : integer := 2;
        PT_BLOCKS   : integer := 4;        -- 64 B payload (CT blocks)
        STRIDE      : integer := 1;
        N0          : integer := 0;
        COINCIDE    : boolean := true;     -- assert a key_valid burst mid-stream
        WARMUP_PKTS : integer := 6;
        BURST_LEN   : integer := 1;        -- burst length in cycles (0 = forever)
        BURST_OFF   : integer := 2;        -- cycles after a packet's IV pulse to start the burst
        C_READY_PCT : integer := 100;
        C_TIMEOUT   : integer := 6000;
        INFILE      : string  := "data/inData.txt"
    );
end entity;

architecture tb of tb_gcm_dec_aes_keyrace is

    constant DATA_WIDTH : integer := 128;
    constant c_TKEEP_W  : integer := DATA_WIDTH/8;

    subtype slv128  is std_logic_vector(DATA_WIDTH-1 downto 0);
    subtype slv96   is std_logic_vector(95 downto 0);
    subtype slv256 is std_logic_vector(255 downto 0);

    constant NBLK_FILE : integer := 8;
    type blk_array is array(0 to NBLK_FILE-1) of slv128;

    constant c_NONCE_HI  : std_logic_vector(63 downto 0) := (others => '0');
    constant C_GLOBAL_TO : time := 80 ms;

    -- input : AAD || CT || ICV (TLAST on ICV);  output : AAD || PT (TLAST on last PT)
    constant TOTAL_IN_BEATS  : integer := AAD_BEATS + PT_BLOCKS + 1;
    constant TOTAL_OUT_BEATS : integer := AAD_BEATS + PT_BLOCKS;

    function ivlo_of(n : integer)  return integer is begin return N0 + n*STRIDE; end;
    function ptidx_of(n, b : integer) return integer is begin return (n + b) mod NBLK_FILE; end;

    function iv_of(n : integer) return slv96 is
    begin
        return c_NONCE_HI & std_logic_vector(to_unsigned(ivlo_of(n), 32));
    end;

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

    signal o_auth_ok     : std_logic;
    signal o_dec_done    : std_logic;
    signal o_DEC_in_proc : std_logic;

    signal w_crypto_key       : slv256;
    signal w_crypto_key_valid : std_logic;
    signal w_crypto_IV        : slv96;
    signal w_crypto_IV_valid  : std_logic;

    signal w_ct_tdata    : slv128;
    signal w_ct_tkeep    : std_logic_vector(c_TKEEP_W-1 downto 0);
    signal w_ct_tvalid   : std_logic;
    signal w_ct_tlast    : std_logic;
    signal w_ct_tready   : std_logic;

    signal w_pt_tdata    : slv128;
    signal w_pt_tkeep    : std_logic_vector(c_TKEEP_W-1 downto 0);
    signal w_pt_tvalid   : std_logic;
    signal w_pt_tlast    : std_logic;
    signal w_pt_tready   : std_logic;

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
    signal r_iv_tick     : std_logic := '0';

begin

    u_glue : entity work.gcm_dec_glue
        generic map (AAD_BEATS => AAD_BEATS, DATA_WIDTH => DATA_WIDTH)
        port map (
            i_clk => clk, i_rstn => rstn,
            i_key => i_key, i_key_valid => i_key_valid,
            i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,
            s_axis_tdata => s_axis_tdata, s_axis_tkeep => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid, s_axis_tlast => s_axis_tlast,
            s_axis_tready => s_axis_tready,
            m_axis_tdata => m_axis_tdata, m_axis_tkeep => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid, m_axis_tlast => m_axis_tlast,
            m_axis_tready => m_axis_tready,
            o_auth_ok => o_auth_ok, o_dec_done => o_dec_done,
            o_DEC_in_proc => o_DEC_in_proc,
            o_crypto_key => w_crypto_key, o_crypto_key_valid => w_crypto_key_valid,
            o_crypto_nonce => w_crypto_IV, o_crypto_nonce_valid => w_crypto_IV_valid,
            m_ct_axis_tdata => w_ct_tdata, m_ct_axis_tkeep => w_ct_tkeep,
            m_ct_axis_tvalid => w_ct_tvalid, m_ct_axis_tlast => w_ct_tlast,
            m_ct_axis_tready => w_ct_tready,
            s_pt_axis_tdata => w_pt_tdata, s_pt_axis_tkeep => w_pt_tkeep,
            s_pt_axis_tvalid => w_pt_tvalid, s_pt_axis_tlast => w_pt_tlast,
            s_pt_axis_tready => w_pt_tready,
            i_crypto_H => w_H, i_crypto_H_valid => w_H_valid,
            i_crypto_E_k => w_E_k, i_crypto_E_k_valid => w_E_k_valid,
            i_crypto_h_stale => w_h_stale,
            i_crypto_in_proc => w_in_proc
        );

    -- crypto core: CT in (from glue m_ct), PT out (to glue s_pt)
    u_core : entity work.AES_algorithm
        generic map (AES_BITS => 128, ROUND_STYLE => "LUT", FLOW_STYLE => "GLOBAL",
                     WRAPPER_KIND => G_KIND, NUM_CORES => NUM_CORES)
        port map (
            i_clk => clk, i_rstn => rstn,
            i_key => w_crypto_key, i_key_valid => w_crypto_key_valid,
            i_nonce => w_crypto_IV, i_nonce_valid => w_crypto_IV_valid,
            s_axis_tdata => w_ct_tdata, s_axis_tvalid => w_ct_tvalid,
            s_axis_tready => w_ct_tready, s_axis_tlast => w_ct_tlast,
            s_axis_tkeep => w_ct_tkeep,
            m_axis_tdata => w_pt_tdata, m_axis_tvalid => w_pt_tvalid,
            m_axis_tready => w_pt_tready, m_axis_tlast => w_pt_tlast,
            m_axis_tkeep => w_pt_tkeep,
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
        file_close(f); files_loaded <= true;
        report "tb: loaded plaintext blocks" severity note;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- p_keystress : SOLE driver of i_key / i_key_valid (initial key, then a
    -- single key change BURST_OFF cycles after a packet's IV, in the bad zone).
    ----------------------------------------------------------------------------
    p_keystress : process
        variable idx : integer := 1;
    begin
        i_key_valid <= '0';
        if not files_loaded then wait until files_loaded; end if;
        wait until rstn = '1';
        i_key <= key_of(0); i_key_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';

        if COINCIDE then
            wait until rising_edge(clk) and r_out_beats >= WARMUP_PKTS*TOTAL_OUT_BEATS;
            wait until rising_edge(clk) and r_iv_tick = '1';
            for i in 1 to BURST_OFF loop wait until rising_edge(clk); end loop;
            if BURST_LEN = 0 then
                loop
                    i_key <= key_of(idx); i_key_valid <= '1';
                    wait until rising_edge(clk); idx := idx + 1;
                end loop;
            else
                for b in 1 to BURST_LEN loop
                    i_key <= key_of(idx); i_key_valid <= '1';
                    wait until rising_edge(clk); idx := idx + 1;
                end loop;
                i_key_valid <= '0';
            end if;
        end if;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- p_stim : IV (time-driven, fresh per packet) + AAD || CT || ICV payload.
    ----------------------------------------------------------------------------
    p_stim : process
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
                    report "tb: FREEZE - s_axis_tready stuck (key swap wedged DEC GCM) pkt="
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
        for i in 1 to 4 loop wait until rising_edge(clk); end loop;

        for p in 0 to NUM_PKTS-1 loop
            pulse_iv(iv_of(p));
            for b in 0 to TOTAL_IN_BEATS-1 loop
                if b < AAD_BEATS then
                    send_beat(file_blocks(ptidx_of(p, b)), false, p, "AAD");
                elsif b < AAD_BEATS + PT_BLOCKS then
                    send_beat(file_blocks(ptidx_of(p, b)), false, p, "CT");
                else
                    send_beat(file_blocks(ptidx_of(p, 0)), true, p, "ICV");  -- ICV beat, TLAST
                end if;
            end loop;
        end loop;
        wait;
    end process;

    p_progress : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '0' then
                r_in_beats <= 0; r_out_beats <= 0;
            else
                if s_axis_tvalid = '1' and s_axis_tready = '1' then
                    r_in_beats <= r_in_beats + 1;
                end if;
                if m_axis_tvalid = '1' and m_axis_tready = '1' then
                    r_out_beats <= r_out_beats + 1;
                end if;
            end if;
        end if;
    end process;

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
                    report "tb: X/U on m_axis_tdata out_pkt=" & integer'image(out_pkt) severity error;
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
                    report "================ GCM-DEC KEYRACE SUMMARY ================" severity note;
                    report "  out packets  = " & integer'image(out_pkt)
                         & " / " & integer'image(NUM_PKTS) severity note;
                    report "  out beats    = " & integer'image(seen)
                         & " / " & integer'image(C_EXP_OUT) severity note;
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
                         & "): DEC GCM wedged by key swap" severity failure;
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

end architecture;
