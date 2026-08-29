----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_flush_xcheck_mc
-- Module Name   : tb_flush_xcheck_mc - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Cross-checks the side-band accounting of AES_multicore_wrapper while
--                 the IV is asserted at swept moments around the flush: o_H_valid must
--                 pulse once per KEY EPOCH (H is per key) and o_E_k_valid once per
--                 PACKET (E(J0) is per packet).
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

entity tb_flush_xcheck_mc is
    generic (
        NUM_PKTS    : integer := 100;
        AES_BITS    : integer := 128;     -- 128 or 256
        ROUND_STYLE : string  := "BRAM";  -- "BRAM" or "LUT"
        FLOW_STYLE  : string  := "GLOBAL";-- "GLOBAL" or "PER_STAGE"
        STRIDE      : integer := 1;       -- IV increment per packet (1 = overlap, enables cross-check)
        N0          : integer := 0;       -- base 48-bit counter
        C_VALID_PCT : integer := 100;     -- s_axis_tvalid duty (input source): 1..100 %
        C_READY_PCT : integer := 100;     -- m_axis_tready duty (output sink) : 1..100 %
        C_FORCE_SCEN : integer := -1;      -- >=0: force this scenario for ALL next-IV injections
        C_ENABLE_DOUBLE : boolean := true; -- false: replace SC_DOUBLE with SC_ONFLUSH
                                           --        (isolates the double-input-on-flush corner)
        INFILE      : string  := "data/inData.txt"
    );
end entity;

architecture tb of tb_flush_xcheck_mc is

    -- Local width constants (AES wrapper uses literal 128 / 256 / 16-bit ports)
    constant c_BLOCK_BITS   : integer := 128;
    constant c_KEY_RAW_BITS : integer := 256;

    ----------------------------------------------------------------------------
    -- Types / subtypes
    ----------------------------------------------------------------------------
    subtype slv128  is std_logic_vector(c_BLOCK_BITS-1   downto 0);
    subtype slv256 is std_logic_vector(c_KEY_RAW_BITS-1 downto 0);

    constant NBLK_FILE : integer := 8;
    type blk_array is array(0 to NBLK_FILE-1) of slv128;

    ----------------------------------------------------------------------------
    -- Timing scenarios (applied to packet n, timed vs packet n-1 flush)
    ----------------------------------------------------------------------------
    constant SC_ONFLUSH  : integer := 0;
    constant SC_AFTER1   : integer := 1;
    constant SC_AFTER2   : integer := 2;
    constant SC_AFTER3   : integer := 3;
    constant SC_SHADOW_E : integer := 4;
    constant SC_SHADOW_L : integer := 5;
    constant SC_DOUBLE   : integer := 6;
    constant N_SCEN      : integer := 7;

    ----------------------------------------------------------------------------
    -- Fixed nonce (high 80 bits of the IV). Zero to match Nonce_Counter.txt.
    ----------------------------------------------------------------------------
    constant c_NONCE_HI : std_logic_vector(79 downto 0) := (others => '0');

    constant C_TIMEOUT       : integer := 5000;       -- per-block stall watchdog (cycles)
    constant C_GLOBAL_TO     : time    := 20 ms;      -- absolute safety timeout

    ----------------------------------------------------------------------------
    -- Parameter functions (all derived from the packet index)
    ----------------------------------------------------------------------------
    function len_of(n : integer)  return integer is begin return 1 + (n mod NBLK_FILE); end;
    function ivlo_of(n : integer) return integer is begin return N0 + n*STRIDE;         end;
    function keyid_of(n : integer) return integer is begin return n / 5;                end;
    function ptidx_of(n, b : integer) return integer is begin return (n + b) mod NBLK_FILE; end;
    function scen_of(n : integer) return integer is begin return n mod N_SCEN;          end;
    function epoch_bnd(n : integer) return boolean is begin return (n mod 5) = 0;       end;

    -- src interface: 96-bit nonce, FIXED PER KEY-EPOCH so every packet in an
    -- epoch yields the identical keystream (the cross-check below exploits this:
    -- any per-packet IV corruption from flush timing makes one packet diverge).
    function iv_of(n : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(16#A50000# + keyid_of(n), 96));
    end;

    -- Decoy nonce for SC_DOUBLE: distinct value, so if the decoy wrongly wins
    -- the keystream diverges and the cross-check fires.
    function decoy_of(n : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(16#A50000# + keyid_of(n) + 16#400000#, 96));
    end;

    function key_of(id : integer) return slv256 is
        variable v : slv256 := (others => '0');
    begin
        v(31 downto 0) := std_logic_vector(to_unsigned(id, 32));
        return v;
    end;

    function total_blocks return integer is
        variable s : integer := 0;
    begin
        for n in 0 to NUM_PKTS-1 loop
            s := s + len_of(n);
        end loop;
        return s;
    end;

    function num_epochs return integer is
    begin
        return (NUM_PKTS + 4) / 5;
    end;

    function scen_name(s : integer) return string is
    begin
        case s is
            when SC_ONFLUSH  => return "ONFLUSH ";
            when SC_AFTER1   => return "AFTER1  ";
            when SC_AFTER2   => return "AFTER2  ";
            when SC_AFTER3   => return "AFTER3  ";
            when SC_SHADOW_E => return "SHADOW_E";
            when SC_SHADOW_L => return "SHADOW_L";
            when SC_DOUBLE   => return "DOUBLE  ";
            when others      => return "??      ";
        end case;
    end;

    constant C_TOTAL_BLOCKS : integer := total_blocks;
    constant C_NUM_EPOCHS   : integer := num_epochs;

    ----------------------------------------------------------------------------
    -- DUT / TB signals
    ----------------------------------------------------------------------------
    signal clk           : std_logic := '0';
    signal rstn          : std_logic := '0';

    signal i_key         : std_logic_vector(255 downto 0) := (others => '0');
    signal i_key_valid   : std_logic;
    signal i_nonce          : std_logic_vector(95 downto 0) := (others => '0');
    signal i_nonce_valid    : std_logic;

    signal s_axis_tdata  : slv128 := (others => '0');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tready : std_logic;
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tkeep  : std_logic_vector(c_BLOCK_BITS/8-1 downto 0) := (others => '0');

    signal m_axis_tdata  : slv128;
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '1';
    signal m_axis_tlast  : std_logic;
    signal m_axis_tkeep  : std_logic_vector(c_BLOCK_BITS/8-1 downto 0);

    signal o_H           : slv128;
    signal o_H_valid     : std_logic;
    signal o_E_k         : slv128;
    signal o_E_k_valid   : std_logic;
    signal o_enc_in_proc : std_logic;

    -- IV/key drive request signals (P_STIM is the sole driver of these;
    -- i_nonce_valid / i_key_valid are the concurrent OR below).
    signal r_iv_value        : std_logic_vector(95 downto 0) := (others => '0');
    signal r_iv_pulse        : std_logic := '0';
    signal r_arm_onflush_iv  : std_logic := '0';
    signal r_key_value       : slv256 := (others => '0');
    signal r_key_pulse       : std_logic := '0';
    signal r_arm_onflush_key : std_logic := '0';

    signal flush_obs     : std_logic;

    signal files_loaded  : boolean := false;
    signal file_blocks   : blk_array := (others => (others => '0'));

begin

    ----------------------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------------------
    dut : entity work.AES_multicore_wrapper
        generic map (
            AES_BITS    => AES_BITS,
            ROUND_STYLE => ROUND_STYLE,
            NUM_CORES   => 4
        )
        port map (
            i_clk         => clk,
            i_rstn        => rstn,
            i_key         => i_key,
            i_key_valid   => i_key_valid,
            i_nonce          => i_nonce,
            i_nonce_valid    => i_nonce_valid,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tkeep  => s_axis_tkeep,
            m_axis_tdata  => m_axis_tdata,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready,
            m_axis_tlast  => m_axis_tlast,
            m_axis_tkeep  => m_axis_tkeep,
            o_H           => o_H,
            o_H_valid     => o_H_valid,
            o_E_k         => o_E_k,
            o_E_k_valid   => o_E_k_valid
        );

    ----------------------------------------------------------------------------
    -- Clock / reset
    ----------------------------------------------------------------------------
    clk  <= not clk after 5 ns;          -- 100 MHz
    rstn <= '0', '1' after 53 ns;

    ----------------------------------------------------------------------------
    -- Output sink: m_axis_tready asserted C_READY_PCT% of cycles (backpressure).
    -- AXIS allows tready to toggle freely, so this is a plain per-cycle coin flip.
    ----------------------------------------------------------------------------
    p_ready : process
        variable s1 : positive := 101;
        variable s2 : positive := 202;
        variable r  : real;
    begin
        if C_READY_PCT >= 100 then
            m_axis_tready <= '1';
            wait;                         -- constant-ready, no toggling
        else
            m_axis_tready <= '1';
            wait until rstn = '1';
            loop
                uniform(s1, s2, r);
                if (r * 100.0) < real(C_READY_PCT) then
                    m_axis_tready <= '1';
                else
                    m_axis_tready <= '0';
                end if;
                wait until rising_edge(clk);
            end loop;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Observed flush == DUT's w_flush_all condition.
    ----------------------------------------------------------------------------
    flush_obs <= '1' when (s_axis_tlast = '1' and s_axis_tvalid = '1'
                           and m_axis_tvalid = '1' and m_axis_tready = '1')
                 else '0';

    ----------------------------------------------------------------------------
    -- IV / key valid: normal pulse OR on-flush combinational pulse.
    ----------------------------------------------------------------------------
    i_nonce        <= r_iv_value;
    i_nonce_valid  <= r_iv_pulse  or (r_arm_onflush_iv  and flush_obs);
    i_key       <= r_key_value;
    i_key_valid <= r_key_pulse or (r_arm_onflush_key and flush_obs);

    ----------------------------------------------------------------------------
    -- Load plaintext blocks from file (hex, one 128-bit block per line).
    ----------------------------------------------------------------------------
    p_load : process
        file     f   : text;
        variable st  : file_open_status;
        variable l   : line;
        variable v   : slv128;
    begin
        file_open(st, f, INFILE, read_mode);
        assert st = open_ok
            report "tb: cannot open " & INFILE severity failure;
        for i in 0 to NBLK_FILE-1 loop
            assert not endfile(f)
                report "tb: inData has fewer than 8 blocks" severity failure;
            readline(f, l);
            hread(l, v);
            file_blocks(i) <= v;
        end loop;
        file_close(f);
        files_loaded <= true;
        report "tb: loaded " & integer'image(NBLK_FILE) & " plaintext blocks from " & INFILE
            severity note;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Stimulus
    ----------------------------------------------------------------------------
    p_stim : process

        procedure waitc(constant k : integer) is
        begin
            for i in 1 to k loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- One-cycle IV (and optionally key) pulse: shadow / S_IDLE / after-flush.
        procedure do_pulse(constant ivv : std_logic_vector(95 downto 0);
                           constant kv  : slv256;
                           constant dk  : boolean) is
        begin
            r_iv_value <= ivv;
            r_iv_pulse <= '1';
            if dk then
                r_key_value <= kv;
                r_key_pulse <= '1';
            end if;
            wait until rising_edge(clk);
            r_iv_pulse  <= '0';
            r_key_pulse <= '0';
        end procedure;

        -- Drive one AXIS plaintext block and wait for the handshake.
        -- Input bubbles (C_VALID_PCT < 100) are inserted BEFORE tvalid is
        -- asserted; once asserted, tvalid is held until tready (AXIS rule).
        procedure send_block(constant data    : slv128;
                             constant last    : boolean;
                             variable s1, s2  : inout positive) is
            variable wd : integer := 0;
            variable gd : integer := 0;
            variable r  : real;
        begin
            -- pre-assert idle bubbles to emulate a C_VALID_PCT%-valid source
            if C_VALID_PCT < 100 then
                loop
                    uniform(s1, s2, r);
                    exit when (r * 100.0) < real(C_VALID_PCT);  -- present now
                    exit when gd >= 1000;                       -- safety: force present
                    gd := gd + 1;
                    s_axis_tvalid <= '0';
                    wait until rising_edge(clk);
                end loop;
            end if;

            s_axis_tdata  <= data;
            s_axis_tkeep  <= (others => '1');
            if last then s_axis_tlast <= '1'; else s_axis_tlast <= '0'; end if;
            s_axis_tvalid <= '1';
            loop
                wait until rising_edge(clk);
                exit when s_axis_tready = '1';
                wd := wd + 1;
                assert wd < C_TIMEOUT
                    report "tb: STALL - s_axis_tready never asserted (lost IV / deadlock?)"
                    severity failure;
            end loop;
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';
        end procedure;

        variable L, sc : integer;
        variable dk    : boolean;
        variable v_s1  : positive := 12345;   -- PRNG state for input bubbles
        variable v_s2  : positive := 6789;
    begin
        -- idle
        s_axis_tvalid <= '0'; s_axis_tlast <= '0';
        s_axis_tdata  <= (others => '0'); s_axis_tkeep <= (others => '0');
        r_iv_pulse <= '0'; r_key_pulse <= '0';
        r_arm_onflush_iv <= '0'; r_arm_onflush_key <= '0';

        if not files_loaded then
            wait until files_loaded;
        end if;
        wait until rstn = '1';
        waitc(2);

        -- Packet 0 setup (S_IDLE direct apply of key+IV).
        do_pulse(iv_of(0), key_of(keyid_of(0)), true);

        for p in 0 to NUM_PKTS-1 loop
            L := len_of(p);
            if p < NUM_PKTS-1 then
                sc := scen_of(p+1);
                if (sc = SC_DOUBLE) and (not C_ENABLE_DOUBLE) then
                    sc := SC_ONFLUSH;     -- isolate: no decoy / no double-injection
                end if;
                if C_FORCE_SCEN >= 0 then sc := C_FORCE_SCEN; end if;
                dk := epoch_bnd(p+1);
            else
                sc := -1;
                dk := false;
            end if;

            report "tb: pkt " & integer'image(p) & " len=" & integer'image(L)
                 & "  next_IV_scenario=" & scen_name(sc)
                 & "  key_change=" & boolean'image(dk)
                 severity note;

            for b in 0 to L-1 loop
                -- Arm on-flush injection of packet p+1's IV before the last block.
                if (b = L-1) and (p < NUM_PKTS-1)
                   and (sc = SC_ONFLUSH or sc = SC_DOUBLE) then
                    r_iv_value       <= iv_of(p+1);
                    r_arm_onflush_iv <= '1';
                    if dk then
                        r_key_value       <= key_of(keyid_of(p+1));
                        r_arm_onflush_key <= '1';
                    end if;
                end if;

                send_block(file_blocks(ptidx_of(p, b)), b = L-1, v_s1, v_s2);

                -- Clear on-flush arm right after the flush handshake.
                if (b = L-1) and (p < NUM_PKTS-1)
                   and (sc = SC_ONFLUSH or sc = SC_DOUBLE) then
                    r_arm_onflush_iv  <= '0';
                    r_arm_onflush_key <= '0';
                end if;

                -- Mid-packet shadow injections (in S_RUN).
                if p < NUM_PKTS-1 then
                    if (sc = SC_SHADOW_E) and (b = 0) and (L >= 2) then
                        do_pulse(iv_of(p+1), key_of(keyid_of(p+1)), dk);
                    elsif (sc = SC_SHADOW_L) and (b = L-2) and (L >= 2) then
                        do_pulse(iv_of(p+1), key_of(keyid_of(p+1)), dk);
                    elsif (sc = SC_DOUBLE) and (b = L-2) and (L >= 2) then
                        -- decoy shadow; the REAL IV arrives on the flush cycle
                        do_pulse(decoy_of(p+1), key_of(keyid_of(p+1)), dk);
                    end if;
                end if;
            end loop;

            -- Post-flush (S_IDLE) injections.
            if p < NUM_PKTS-1 then
                if sc = SC_AFTER1 then
                    waitc(1); do_pulse(iv_of(p+1), key_of(keyid_of(p+1)), dk);
                elsif sc = SC_AFTER2 then
                    waitc(2); do_pulse(iv_of(p+1), key_of(keyid_of(p+1)), dk);
                elsif sc = SC_AFTER3 then
                    waitc(3); do_pulse(iv_of(p+1), key_of(keyid_of(p+1)), dk);
                elsif (sc = SC_SHADOW_E or sc = SC_SHADOW_L) and (L < 2) then
                    -- 1-block packet: no room to stage a shadow -> fall back.
                    waitc(1); do_pulse(iv_of(p+1), key_of(keyid_of(p+1)), dk);
                end if;
            end if;
        end loop;

        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Monitor / scoreboard
    ----------------------------------------------------------------------------
    p_mon : process
        type ks_rec is record
            v : boolean;
            d : slv128;
        end record;
        type ks_row is array(0 to 255) of ks_rec;
        type ks_tab is array(0 to 31)  of ks_row;

        variable ks      : ks_tab := (others => (others => (false, (others => '0'))));
        variable mon_pkt : integer := 0;
        variable blk     : integer := 0;
        variable seen    : integer := 0;
        variable errc    : integer := 0;
        variable hcnt    : integer := 0;
        variable ekcnt   : integer := 0;
        variable kid, cnt : integer;
        variable ctv, ptv, ksv : slv128;
    begin
        wait until rstn = '1';
        loop
            wait until rising_edge(clk);

            if o_H_valid   = '1' then hcnt  := hcnt  + 1; end if;
            if o_E_k_valid = '1' then ekcnt := ekcnt + 1; end if;

            if m_axis_tvalid = '1' and m_axis_tready = '1' then
                ctv := m_axis_tdata;
                ptv := s_axis_tdata;

                if is_x(ctv) then
                    errc := errc + 1;
                    report "tb: X/U on m_axis_tdata pkt=" & integer'image(mon_pkt)
                         & " blk=" & integer'image(blk) severity error;
                end if;

                ksv := ctv xor ptv;            -- recovered keystream E_K(nonce||cnt)
                kid := keyid_of(mon_pkt);
                cnt := blk;   -- nonce fixed per epoch -> keystream depends only on block index

                if kid <= 31 and cnt >= 0 and cnt <= 255 then
                    if ks(kid)(cnt).v then
                        if ks(kid)(cnt).d /= ksv then
                            errc := errc + 1;
                            report "tb: KEYSTREAM MISMATCH (IV corruption?) pkt="
                                 & integer'image(mon_pkt) & " blk=" & integer'image(blk)
                                 & " keyid=" & integer'image(kid)
                                 & " cnt="   & integer'image(cnt) severity error;
                        end if;
                    else
                        ks(kid)(cnt) := (true, ksv);
                    end if;
                end if;

                blk  := blk  + 1;
                seen := seen + 1;

                if m_axis_tlast = '1' then
                    if blk /= len_of(mon_pkt) then
                        errc := errc + 1;
                        report "tb: BLOCK COUNT MISMATCH pkt=" & integer'image(mon_pkt)
                             & " got=" & integer'image(blk)
                             & " exp=" & integer'image(len_of(mon_pkt)) severity error;
                    end if;
                    blk     := 0;
                    mon_pkt := mon_pkt + 1;
                end if;

                if seen = C_TOTAL_BLOCKS then
                    report "==================== TB SUMMARY ====================" severity note;
                    report "  valid/ready = " & integer'image(C_VALID_PCT) & "% / "
                         & integer'image(C_READY_PCT) & "%" severity note;
                    report "  packets    = " & integer'image(mon_pkt)
                         & " / " & integer'image(NUM_PKTS) severity note;
                    report "  blocks     = " & integer'image(seen)
                         & " / " & integer'image(C_TOTAL_BLOCKS) severity note;
                    report "  H pulses   = " & integer'image(hcnt)
                         & " (exp " & integer'image(C_NUM_EPOCHS) & ")" severity note;
                    report "  EK pulses  = " & integer'image(ekcnt)
                         & " (exp " & integer'image(NUM_PKTS) & ")" severity note;
                    report "  errors     = " & integer'image(errc) severity note;

                    if hcnt /= C_NUM_EPOCHS then
                        errc := errc + 1;
                        report "tb: H pulse count wrong" severity error;
                    end if;
                    if ekcnt /= NUM_PKTS then
                        errc := errc + 1;
                        report "tb: EK pulse count wrong" severity error;
                    end if;

                    if errc = 0 then
                        report "RESULT: PASS" severity note;
                    else
                        report "RESULT: FAIL (" & integer'image(errc) & " errors)"
                            severity failure;
                    end if;
                    report "===================================================" severity note;
                    finish;
                end if;
            end if;
        end loop;
    end process;

    ----------------------------------------------------------------------------
    -- Absolute safety timeout
    ----------------------------------------------------------------------------
    p_watchdog : process
    begin
        wait for C_GLOBAL_TO;
        report "tb: GLOBAL TIMEOUT - simulation did not finish" severity failure;
    end process;

end architecture;
