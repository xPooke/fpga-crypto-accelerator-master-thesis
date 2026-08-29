----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_ipsec_throughput
-- Module Name   : tb_ipsec_throughput - sim
-- Tool Version  : Vivado Simulator 2025.1 (xvhdl -2008 / xelab / xsim)
--
-- Description   : Cycle-accurate throughput measurement for the complete IPsec
--                 encryption IP (ipsec_gcm_enc_top: input skid + SPLIT_demux +
--                 gcm_enc_glue + AES_algorithm + output skid + MERGE_mux).
--                 This is the full-IP counterpart of tb_gcm_throughput in
--                 tests/gcm_core_AES: it streams G_NUM_PACKETS same-key packets
--                 back to back (one IPsec SA, IV incremented per packet by a
--                 1-cycle i_nonce_valid pulse near the end of the previous
--                 packet, which the AES wrapper's shadow register applies at
--                 the packet boundary), with the source always valid and the
--                 sink always ready, and counts clock cycles.
--
--                 Measured window: from the first accepted input beat to the
--                 output beat carrying TLAST of the last packet, so the window
--                 contains everything the IP really pays for -- pipeline fill,
--                 per-packet E_K(J0), the ICV beat, segment mux switching.
--                 H = E_K(0) is computed once per key before the first packet;
--                 both AES wrappers recompute it only on a key change, so with
--                 one SA it is setup cost, not per-packet cost.
--
--                   payload bits/clock = G_NUM_PACKETS * G_PT_BYTES * 8 / cycles
--                   wire    bits/clock = collected output bytes * 8 / cycles
--
--                 Correctness runs alongside the measurement, because a timing
--                 number from a broken run is worthless:
--                   * G_CHAIN = 0: per packet, the output must carry exactly
--                     BYPASS + AAD + PT + 16 ICV bytes, the bypass and AAD
--                     bytes must be untouched, the ciphertext must differ from
--                     the plaintext and the ICV must not be all zero.
--                   * G_CHAIN = 1: the output of ipsec_gcm_enc_top feeds
--                     ipsec_gcm_dec_top; every packet must round-trip
--                     byte-identical and every tag must verify (o_auth_ok on
--                     each o_dec_done pulse). The measured window then also
--                     covers the decryptor; the encryptor's own window is
--                     reported separately from a tap on the enc output.
--                 A run that fails any check reports RESULT: FAIL and its
--                 timing must be discarded.
--
--                 Packet geometry is the IPsec ESP tunnel case of the B3
--                 synthesis measurement: 34 bypass bytes (Ethernet II 14 +
--                 outer IPv4 20), 16 AAD bytes (ESP header 8 + explicit IV 8),
--                 then G_PT_BYTES of payload; default 1504 B = 94 full bus
--                 words, matching the 1500 B row of the short-packet table.
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;

entity tb_ipsec_throughput is
    generic (
        G_WRAPPER_KIND : string   := "MULTICORE";  -- "UNROLLED" or "MULTICORE"
        G_NUM_CORES    : integer  := 15;           -- MULTICORE only
        G_ROUND_STYLE  : string   := "LUT";        -- "BRAM" or "LUT"
        G_FLOW_STYLE   : string   := "GLOBAL";     -- UNROLLED only
        G_MULT_CYCLES  : integer  := 1;            -- GHASH multiply: 1 or 2 clocks
        G_AES_BITS     : integer  := 256;
        G_BYPASS_BYTES : positive := 34;           -- Ethernet 14 + outer IPv4 20
        G_AAD_BYTES    : positive := 16;           -- ESP header 8 + explicit IV 8
        G_PT_BYTES     : positive := 1504;         -- payload; 94 full 128-bit words
        G_NUM_PACKETS  : positive := 8;
        G_CHAIN        : integer  := 0             -- 1 = enc -> dec round-trip chain
    );
end entity;

architecture sim of tb_ipsec_throughput is

    constant c_CLK_PERIOD : time     := 10 ns;
    constant c_DATA_WIDTH : positive := 128;
    constant c_BUS_BYTES  : positive := c_DATA_WIDTH / 8;

    constant c_TOTAL_IN  : positive := G_BYPASS_BYTES + G_AAD_BYTES + G_PT_BYTES;
                           -- input bytes per packet: 34 + 16 + 1504 = 1554
    constant c_IN_BEATS  : positive := (c_TOTAL_IN + c_BUS_BYTES - 1) / c_BUS_BYTES;
                           -- input beats per packet: ceil(1554/16) = 98
    constant c_TOTAL_ENC : positive := c_TOTAL_IN + 16;
                           -- enc output bytes per packet (adds the ICV): 1570
    -- Bytes per packet expected at the measured (final) output: the protected
    -- packet in enc-only mode, the recovered plain packet in chain mode.
    constant c_EXP_OUT_BYTES : positive := c_TOTAL_ENC - 16 * G_CHAIN;

    -- Generous run bound: 8x the ideal cycle count plus configuration time.
    constant c_TIMEOUT_CYCLES : positive :=
        8 * G_NUM_PACKETS * (c_IN_BEATS + 64) + 4000;

    type byte_arr_t is array(natural range <>) of std_logic_vector(7 downto 0);

    -- Per-packet input byte pattern; the packet term catches cross-packet mixing.
    function pattern_byte(pkt : natural; idx : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((idx*7 + pkt*29 + 13) mod 256, 8));
    end function;

    function count_ones(v : std_logic_vector) return natural is
        variable v_n : natural := 0;
    begin
        for i in v'range loop
            if v(i) = '1' then
                v_n := v_n + 1;
            end if;
        end loop;
        return v_n;
    end function;

    signal i_clk  : std_logic := '0';
    signal i_rstn : std_logic := '0';

    signal i_key         : std_logic_vector(255 downto 0) := (others => '0');
    signal i_key_valid   : std_logic := '0';
    signal i_nonce       : std_logic_vector(95 downto 0)  := (others => '0');
    signal i_nonce_valid : std_logic := '0';

    -- TB -> enc top
    signal s_tdata  : std_logic_vector(c_DATA_WIDTH-1 downto 0) := (others => '0');
    signal s_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0)  := (others => '0');
    signal s_tvalid : std_logic := '0';
    signal s_tlast  : std_logic := '0';
    signal s_tready : std_logic;

    -- enc top output (feeds the sink directly, or the dec top when G_CHAIN = 1)
    signal w_enc_tdata  : std_logic_vector(c_DATA_WIDTH-1 downto 0);
    signal w_enc_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_enc_tvalid : std_logic;
    signal w_enc_tlast  : std_logic;
    signal w_enc_tready : std_logic;

    -- measured (final) output: enc output or dec output, per G_CHAIN
    signal w_fin_tdata  : std_logic_vector(c_DATA_WIDTH-1 downto 0);
    signal w_fin_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_fin_tvalid : std_logic;
    signal w_fin_tlast  : std_logic;
    signal w_fin_tready : std_logic := '0';

    -- dec side-band; keeps its init value when the dec top is not instantiated
    signal w_auth_ok  : std_logic := '0';
    signal w_dec_done : std_logic := '0';

    signal w_enc_in_proc : std_logic;
    signal w_txenc       : std_logic_vector(31 downto 0);

    ----------------------------------------------------------------------------
    -- Measurement state (pattern of tb_gcm_throughput: the window opens on the
    -- first accepted input beat and the cycle carrying the closing TLAST counts)
    ----------------------------------------------------------------------------
    signal r_cycles     : natural   := 0;   -- free-running once the window opens
    signal r_counting   : std_logic := '0';
    signal r_done       : std_logic := '0';
    signal r_in_beats   : natural   := 0;   -- accepted input beats (sanity)

    signal r_enc_beats  : natural := 0;     -- enc output beats
    signal r_enc_bytes  : natural := 0;     -- enc output bytes (TKEEP popcount)
    signal r_enc_pkts   : natural := 0;     -- enc output TLAST count
    signal r_enc_cycles : natural := 0;     -- window close at the enc output

    signal r_fin_beats  : natural := 0;     -- final output beats
    signal r_fin_bytes  : natural := 0;     -- final output bytes
    signal r_fin_pkts   : natural := 0;     -- final output TLAST count
    signal r_fin_cycles : natural := 0;     -- window close at the final output

    signal r_auth_events : natural := 0;    -- o_dec_done pulses seen
    signal r_auth_ok_cnt : natural := 0;    -- of which o_auth_ok = '1'

    signal r_errors : natural := 0;         -- structural / content check failures

begin

    -- The per-packet IV pulse rides on input beat c_IN_BEATS-2, so packets must
    -- be at least three beats long. The measured geometry is 98 beats.
    assert c_IN_BEATS >= 3
        report "tb_ipsec_throughput: packet must span at least 3 input beats"
        severity failure;
    assert G_CHAIN = 0 or G_CHAIN = 1
        report "tb_ipsec_throughput: G_CHAIN must be 0 or 1"
        severity failure;

    i_clk  <= not i_clk after c_CLK_PERIOD / 2;
    i_rstn <= '0', '1' after 33 ns;

    --------------------------------------------------------------------------
    -- Encryption IP under test
    --------------------------------------------------------------------------
    u_enc : entity work.ipsec_gcm_enc_top
        generic map (
            DATA_WIDTH   => c_DATA_WIDTH,
            BYPASS_EN    => true,
            BYPASS_BYTES => G_BYPASS_BYTES,
            AAD_BYTES    => G_AAD_BYTES,
            MULT_CYCLES  => G_MULT_CYCLES,
            AES_BITS     => G_AES_BITS,
            ROUND_STYLE  => G_ROUND_STYLE,
            FLOW_STYLE   => G_FLOW_STYLE,
            WRAPPER_KIND => G_WRAPPER_KIND,
            NUM_CORES    => G_NUM_CORES
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            i_key         => i_key,
            i_key_valid   => i_key_valid,
            i_nonce       => i_nonce,
            i_nonce_valid => i_nonce_valid,

            s_axis_tdata  => s_tdata,
            s_axis_tkeep  => s_tkeep,
            s_axis_tvalid => s_tvalid,
            s_axis_tlast  => s_tlast,
            s_axis_tready => s_tready,

            m_axis_tdata  => w_enc_tdata,
            m_axis_tkeep  => w_enc_tkeep,
            m_axis_tvalid => w_enc_tvalid,
            m_axis_tlast  => w_enc_tlast,
            m_axis_tready => w_enc_tready,

            o_ENC_in_proc => w_enc_in_proc,
            o_TxENC       => w_txenc
        );

    --------------------------------------------------------------------------
    -- Sink attachment: straight to the sink, or through the decryption IP
    --------------------------------------------------------------------------
    gen_single : if G_CHAIN = 0 generate
        w_fin_tdata  <= w_enc_tdata;
        w_fin_tkeep  <= w_enc_tkeep;
        w_fin_tvalid <= w_enc_tvalid;
        w_fin_tlast  <= w_enc_tlast;
        w_enc_tready <= w_fin_tready;
    end generate gen_single;

    gen_chain : if G_CHAIN = 1 generate
        u_dec : entity work.ipsec_gcm_dec_top
            generic map (
                DATA_WIDTH   => c_DATA_WIDTH,
                BYPASS_EN    => true,
                BYPASS_BYTES => G_BYPASS_BYTES,
                AAD_BYTES    => G_AAD_BYTES,
                MULT_CYCLES  => G_MULT_CYCLES,
                AES_BITS     => G_AES_BITS,
                ROUND_STYLE  => G_ROUND_STYLE,
                FLOW_STYLE   => G_FLOW_STYLE,
                WRAPPER_KIND => G_WRAPPER_KIND,
                NUM_CORES    => G_NUM_CORES
            )
            port map (
                i_clk  => i_clk,
                i_rstn => i_rstn,

                i_key         => i_key,
                i_key_valid   => i_key_valid,
                i_nonce       => i_nonce,
                i_nonce_valid => i_nonce_valid,

                s_axis_tdata  => w_enc_tdata,
                s_axis_tkeep  => w_enc_tkeep,
                s_axis_tvalid => w_enc_tvalid,
                s_axis_tlast  => w_enc_tlast,
                s_axis_tready => w_enc_tready,

                m_axis_tdata  => w_fin_tdata,
                m_axis_tkeep  => w_fin_tkeep,
                m_axis_tvalid => w_fin_tvalid,
                m_axis_tlast  => w_fin_tlast,
                m_axis_tready => w_fin_tready,

                o_auth_ok     => w_auth_ok,
                o_dec_done    => w_dec_done,
                o_DEC_in_proc => open
            );
    end generate gen_chain;

    -- Sink is always ready: the measurement must see the IP's own rhythm,
    -- not an artificial stall.
    w_fin_tready <= i_rstn;

    ----------------------------------------------------------------------------
    -- Driver. One key pulse for the whole batch (one IPsec SA), then packets
    -- back to back with the source always valid. The IV of packet n+1 is
    -- pulsed for exactly one clock while beat c_IN_BEATS-2 of packet n is on
    -- the bus: both AES wrappers are then deep inside packet n (S_RUN), so the
    -- pulse lands in the shadow IV register and applies at the packet
    -- boundary -- the same protocol tb_gcm_throughput uses on the bare core.
    ----------------------------------------------------------------------------
    p_DRIVE : process
        variable v_iv   : unsigned(95 downto 0);
        variable v_idx  : natural;
        variable v_data : std_logic_vector(c_DATA_WIDTH-1 downto 0);
        variable v_keep : std_logic_vector(c_BUS_BYTES-1 downto 0);
    begin
        s_tvalid <= '0';
        s_tlast  <= '0';
        wait until i_rstn = '1';
        wait until rising_edge(i_clk);

        -- Key: one SA for the whole run
        for b in 0 to 31 loop
            i_key(8*b+7 downto 8*b) <= std_logic_vector(to_unsigned((b*17 + 3) mod 256, 8));
        end loop;
        wait until rising_edge(i_clk);
        i_key_valid <= '1';
        wait until rising_edge(i_clk);
        i_key_valid <= '0';
        for k in 1 to 4 loop
            wait until rising_edge(i_clk);
        end loop;

        -- IV of the first packet (direct latch: the wrappers are idle)
        v_iv    := unsigned'(x"a5a5cafe0000000000000001");
        i_nonce <= std_logic_vector(v_iv);
        i_nonce_valid <= '1';
        wait until rising_edge(i_clk);
        i_nonce_valid <= '0';
        wait until rising_edge(i_clk);

        -- Packets, back to back, source never idles
        for n in 0 to G_NUM_PACKETS-1 loop
            for b in 0 to c_IN_BEATS-1 loop
                v_data := (others => '0');
                v_keep := (others => '0');
                for lane in 0 to c_BUS_BYTES-1 loop
                    v_idx := b*c_BUS_BYTES + lane;
                    if v_idx < c_TOTAL_IN then
                        v_data(8*lane+7 downto 8*lane) := pattern_byte(n, v_idx);
                        v_keep(lane) := '1';
                    end if;
                end loop;

                s_tdata  <= v_data;
                s_tkeep  <= v_keep;
                s_tvalid <= '1';
                if b = c_IN_BEATS-1 then
                    s_tlast <= '1';
                else
                    s_tlast <= '0';
                end if;

                -- Stage the next packet's IV in the shadow register
                if b = c_IN_BEATS-2 and n < G_NUM_PACKETS-1 then
                    v_iv    := v_iv + 1;
                    i_nonce <= std_logic_vector(v_iv);
                    i_nonce_valid <= '1';
                end if;

                loop
                    wait until rising_edge(i_clk);
                    i_nonce_valid <= '0';    -- the IV pulse lasts one clock
                    exit when s_tready = '1';
                end loop;
            end loop;
        end loop;

        s_tvalid <= '0';
        s_tlast  <= '0';
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Cycle counting. Window opens on the first accepted input beat; the enc
    -- and the final output each latch the running count on the TLAST of their
    -- last packet, the same convention as tb_gcm_throughput (the closing
    -- cycle is counted).
    ----------------------------------------------------------------------------
    p_MEAS : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_cycles     <= 0;
                r_counting   <= '0';
                r_done       <= '0';
                r_in_beats   <= 0;
                r_enc_beats  <= 0;
                r_enc_bytes  <= 0;
                r_enc_pkts   <= 0;
                r_enc_cycles <= 0;
                r_fin_beats  <= 0;
                r_fin_bytes  <= 0;
                r_fin_pkts   <= 0;
                r_fin_cycles <= 0;
                r_auth_events <= 0;
                r_auth_ok_cnt <= 0;
            else
                if s_tvalid = '1' and s_tready = '1' then
                    r_in_beats <= r_in_beats + 1;
                    if r_counting = '0' and r_done = '0' then
                        r_counting <= '1';
                        r_cycles   <= 1;
                    end if;
                end if;
                if r_counting = '1' then
                    r_cycles <= r_cycles + 1;
                end if;

                -- Tap on the enc output (equals the final output when G_CHAIN=0)
                if w_enc_tvalid = '1' and w_enc_tready = '1' then
                    r_enc_beats <= r_enc_beats + 1;
                    r_enc_bytes <= r_enc_bytes + count_ones(w_enc_tkeep);
                    if w_enc_tlast = '1' then
                        r_enc_pkts <= r_enc_pkts + 1;
                        if r_enc_pkts + 1 = G_NUM_PACKETS then
                            r_enc_cycles <= r_cycles + 1;
                        end if;
                    end if;
                end if;

                -- Final (measured) output
                if w_fin_tvalid = '1' and w_fin_tready = '1' then
                    r_fin_beats <= r_fin_beats + 1;
                    r_fin_bytes <= r_fin_bytes + count_ones(w_fin_tkeep);
                    if w_fin_tlast = '1' then
                        r_fin_pkts <= r_fin_pkts + 1;
                        if r_fin_pkts + 1 = G_NUM_PACKETS then
                            r_fin_cycles <= r_cycles + 1;
                            r_counting   <= '0';
                            r_done       <= '1';
                        end if;
                    end if;
                end if;

                -- Per-packet tag verdicts (chain mode only; idle otherwise)
                if w_dec_done = '1' then
                    r_auth_events <= r_auth_events + 1;
                    if w_auth_ok = '1' then
                        r_auth_ok_cnt <= r_auth_ok_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Content checker on the final output. Collects the byte stream of each
    -- packet through TKEEP and checks it on TLAST, so a broken configuration
    -- can never be mistaken for a fast one.
    ----------------------------------------------------------------------------
    p_CHECK : process
        variable v_col  : byte_arr_t(0 to c_EXP_OUT_BYTES + 4*c_BUS_BYTES - 1);
        variable v_cnt  : natural := 0;
        variable v_pkt  : natural := 0;
        variable v_err  : natural := 0;
        variable v_diff : natural;
        variable v_icv_nz : boolean;
    begin
        wait until i_rstn = '1';

        while v_pkt < G_NUM_PACKETS loop
            wait until rising_edge(i_clk);
            if w_fin_tvalid = '1' and w_fin_tready = '1' then
                for lane in 0 to c_BUS_BYTES-1 loop
                    if w_fin_tkeep(lane) = '1' then
                        if v_cnt <= v_col'high then
                            v_col(v_cnt) := w_fin_tdata(8*lane+7 downto 8*lane);
                        end if;
                        v_cnt := v_cnt + 1;
                    end if;
                end loop;

                if w_fin_tlast = '1' then
                    -- (1) byte count
                    if v_cnt /= c_EXP_OUT_BYTES then
                        report "PKT " & integer'image(v_pkt) & " LENGTH: got "
                             & integer'image(v_cnt) & " expected "
                             & integer'image(c_EXP_OUT_BYTES) severity error;
                        v_err := v_err + 1;
                    else
                        -- (2) bypass and AAD must pass through untouched
                        for i in 0 to G_BYPASS_BYTES + G_AAD_BYTES - 1 loop
                            if v_col(i) /= pattern_byte(v_pkt, i) then
                                report "PKT " & integer'image(v_pkt)
                                     & " HEADER byte " & integer'image(i)
                                     & " corrupted" severity error;
                                v_err := v_err + 1;
                                exit;
                            end if;
                        end loop;

                        if G_CHAIN = 0 then
                            -- (3) ciphertext present: the vast majority of the
                            -- payload bytes must differ from the plaintext
                            v_diff := 0;
                            for i in 0 to G_PT_BYTES-1 loop
                                if v_col(G_BYPASS_BYTES + G_AAD_BYTES + i)
                                   /= pattern_byte(v_pkt, G_BYPASS_BYTES + G_AAD_BYTES + i) then
                                    v_diff := v_diff + 1;
                                end if;
                            end loop;
                            if v_diff < G_PT_BYTES/2 then
                                report "PKT " & integer'image(v_pkt)
                                     & " CT looks like PT (" & integer'image(v_diff)
                                     & " of " & integer'image(G_PT_BYTES)
                                     & " bytes differ)" severity error;
                                v_err := v_err + 1;
                            end if;
                            -- (4) ICV present and not all zero
                            v_icv_nz := false;
                            for i in c_EXP_OUT_BYTES-16 to c_EXP_OUT_BYTES-1 loop
                                if v_col(i) /= x"00" then
                                    v_icv_nz := true;
                                end if;
                            end loop;
                            if not v_icv_nz then
                                report "PKT " & integer'image(v_pkt)
                                     & " ICV is all zero" severity error;
                                v_err := v_err + 1;
                            end if;
                        else
                            -- (3') chain: full byte-identical round-trip
                            for i in 0 to c_TOTAL_IN-1 loop
                                if v_col(i) /= pattern_byte(v_pkt, i) then
                                    report "PKT " & integer'image(v_pkt)
                                         & " ROUND-TRIP byte " & integer'image(i)
                                         & " mismatch" severity error;
                                    v_err := v_err + 1;
                                    exit;
                                end if;
                            end loop;
                        end if;
                    end if;

                    v_pkt := v_pkt + 1;
                    v_cnt := 0;
                end if;
            end if;
        end loop;

        r_errors <= v_err;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Report. Human-readable summary plus one machine-readable CSV line the
    -- sweep script greps; every number is straight from the counters above.
    ----------------------------------------------------------------------------
    p_REPORT : process
        variable v_l        : line;
        variable v_pass     : boolean;
        variable v_pay_bits : real;
        variable v_pay_bpc  : real;
        variable v_wire_bpc : real;
    begin
        wait until r_done = '1';
        -- Let p_CHECK finish the last packet's verdict and settle r_errors
        for k in 1 to 4 loop
            wait until rising_edge(i_clk);
        end loop;

        v_pay_bits := real(G_NUM_PACKETS) * real(G_PT_BYTES) * 8.0;
        if r_fin_cycles > 0 then
            v_pay_bpc  := v_pay_bits / real(r_fin_cycles);
            v_wire_bpc := real(r_fin_bytes) * 8.0 / real(r_fin_cycles);
        else
            v_pay_bpc  := 0.0;
            v_wire_bpc := 0.0;
        end if;

        report "==== IPsec IP throughput ====";
        report "config      : " & G_WRAPPER_KIND & "/" & G_ROUND_STYLE
             & "  cores=" & integer'image(G_NUM_CORES)
             & "  mult="  & integer'image(G_MULT_CYCLES)
             & "  chain=" & integer'image(G_CHAIN);
        report "packet      : bypass=" & integer'image(G_BYPASS_BYTES)
             & " aad=" & integer'image(G_AAD_BYTES)
             & " pt="  & integer'image(G_PT_BYTES)
             & " B  in_beats=" & integer'image(c_IN_BEATS)
             & "  n=" & integer'image(G_NUM_PACKETS);
        report "cycles      : " & integer'image(r_fin_cycles)
             & "  (enc output closed at " & integer'image(r_enc_cycles) & ")";
        report "in beats    : " & integer'image(r_in_beats);
        report "out         : " & integer'image(r_fin_beats) & " beats, "
             & integer'image(r_fin_bytes) & " bytes  (enc: "
             & integer'image(r_enc_beats) & " beats, "
             & integer'image(r_enc_bytes) & " bytes)";
        report "payload b/c : " & real'image(v_pay_bpc);
        report "wire    b/c : " & real'image(v_wire_bpc);
        if G_CHAIN = 1 then
            report "auth        : " & integer'image(r_auth_ok_cnt) & " of "
                 & integer'image(r_auth_events) & " tags verified";
        end if;

        write(v_l, string'("CSV,"));
        write(v_l, G_WRAPPER_KIND);        write(v_l, string'(","));
        write(v_l, G_NUM_CORES);           write(v_l, string'(","));
        write(v_l, G_MULT_CYCLES);         write(v_l, string'(","));
        write(v_l, G_ROUND_STYLE);         write(v_l, string'(","));
        write(v_l, G_CHAIN);               write(v_l, string'(","));
        write(v_l, G_NUM_PACKETS);         write(v_l, string'(","));
        write(v_l, G_PT_BYTES);            write(v_l, string'(","));
        write(v_l, r_in_beats);            write(v_l, string'(","));
        write(v_l, r_fin_cycles);          write(v_l, string'(","));
        write(v_l, r_fin_beats);           write(v_l, string'(","));
        write(v_l, r_fin_bytes);           write(v_l, string'(","));
        write(v_l, r_enc_cycles);          write(v_l, string'(","));
        write(v_l, r_enc_beats);           write(v_l, string'(","));
        write(v_l, r_enc_bytes);           write(v_l, string'(","));
        write(v_l, r_auth_ok_cnt);         write(v_l, string'(","));
        write(v_l, r_errors);
        writeline(output, v_l);

        v_pass := (r_errors = 0)
              and (r_in_beats = G_NUM_PACKETS * c_IN_BEATS)
              and (r_fin_pkts = G_NUM_PACKETS)
              and (r_fin_bytes = G_NUM_PACKETS * c_EXP_OUT_BYTES)
              and (G_CHAIN = 0 or (r_auth_ok_cnt = G_NUM_PACKETS
                                   and r_auth_events = G_NUM_PACKETS));
        if v_pass then
            report "RESULT: PASS";
        else
            report "RESULT: FAIL" severity error;
        end if;
        finish;
    end process;

    p_TIMEOUT : process
    begin
        wait for c_TIMEOUT_CYCLES * c_CLK_PERIOD;
        report "RESULT: FAIL (timeout - possible deadlock)" severity error;
        finish;
    end process;

end architecture;
