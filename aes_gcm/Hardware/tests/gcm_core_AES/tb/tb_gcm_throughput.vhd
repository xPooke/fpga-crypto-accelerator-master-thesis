----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_gcm_throughput
-- Module Name   : tb_gcm_throughput - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys -frelaxed)
--
-- Description   : Cycle-accurate throughput measurement for the AES-GCM
--                 encryptor.  This is the AES-GCM counterpart of the SHA-3
--                 tb_sha3_throughput: it does NOT check ciphertext (the KAT
--                 suites already do that), it measures how many payload bits
--                 the core retires per clock under a given configuration and
--                 a given backpressure profile.
--
--                 Measured window: from the first accepted input beat to the
--                 output beat carrying TLAST of the last packet.  That window
--                 therefore contains everything the core really pays for --
--                 pipeline fill, H and E_K(J0) per key/nonce, the ICV beat and
--                 any stall the profile imposes.
--
--                 bits/clock = G_NUM_PACKETS * G_PKT_BEATS * 128 / cycles
--
--                 The ICV beat is counted in the TIME but not in the PAYLOAD,
--                 because that is what it costs in a real link.
--
--                 A structural check runs alongside: the number of output
--                 beats must be NUM_PACKETS * (PKT_BEATS + 1), i.e. ciphertext
--                 plus one ICV beat per packet, with AAD_BEATS = 0.  A run that
--                 fails this is reported and its timing discarded, so a broken
--                 configuration can never be mistaken for a fast one.
--
-- Revision      :
--   0.01 - August 2026 - File Created
--
-- Additional Comments :
--   DATA_WIDTH is fixed at 128.  Unlike SHA-3, where the bus width enters the
--   bottleneck model through rate/DATA_WIDTH, the AES block is always 128 bits,
--   so narrowing the bus would only serialise the input for no design reason.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use std.textio.all;

entity tb_gcm_throughput is
    generic (
        G_WRAPPER_KIND  : string   := "UNROLLED";   -- "UNROLLED" or "MULTICORE"
        G_NUM_CORES     : integer  := 4;            -- used only by MULTICORE
        G_ROUND_STYLE   : string   := "BRAM";       -- "BRAM" or "LUT"
        G_FLOW_STYLE    : string   := "GLOBAL";     -- "GLOBAL" or "PER_STAGE"
        G_MULT_CYCLES   : integer  := 2;            -- GHASH: 1 or 2 clocks
        G_AES_BITS      : integer  := 256;
        G_PKT_BEATS     : integer  := 256;          -- payload beats per packet
        G_NUM_PACKETS   : integer  := 8;
        G_IN_VALID_PCT  : integer  := 100;          -- slave TVALID duty
        G_OUT_READY_PCT : integer  := 100;          -- master TREADY duty
        -- Bursty sink: when G_BURST_GO > 0 the sink alternates deterministically,
        -- GO cycles ready then STALL cycles not ready, instead of the per-cycle
        -- random throttle.  A per-cycle random throttle can never build a burst,
        -- so it makes the sink itself the bottleneck and hides the flow style.
        G_BURST_GO      : integer  := 0;
        G_BURST_STALL   : integer  := 0;
        -- Periodic source gating, deliberately out of phase with the sink.  This
        -- is the one profile shape in which PER_STAGE can beat GLOBAL: gaps on
        -- the input open bubbles INSIDE the pipeline, and a stalled output then
        -- gives PER_STAGE time to squeeze them out, which GLOBAL can never do
        -- because all its stages move on a single shared enable.  Sink-only
        -- throttling never creates such a bubble, so it cannot separate the two.
        G_SRC_GO        : integer  := 0;            -- 0 disables source gating
        G_SRC_STALL     : integer  := 0;
        G_SINK_PHASE    : integer  := 0;            -- sink burst offset [clocks]
        G_SEED          : positive := 1
    );
end entity;

architecture sim of tb_gcm_throughput is

    constant c_CLK_PERIOD : time    := 5 ns;
    constant c_DATA_WIDTH : integer := 128;

    -- Ciphertext beats plus one ICV beat per packet (AAD_BEATS = 0).
    constant c_EXP_OUT_BEATS : integer := G_NUM_PACKETS * (G_PKT_BEATS + 1);

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';

    signal i_key         : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '0');
    signal i_key_valid   : std_logic := '0';
    signal i_nonce       : std_logic_vector(95 downto 0) := (others => '0');
    signal i_nonce_valid : std_logic := '0';

    signal s_axis_tdata  : std_logic_vector(c_DATA_WIDTH-1 downto 0) := (others => '0');
    signal s_axis_tkeep  : std_logic_vector(c_DATA_WIDTH/8-1 downto 0) := (others => '1');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tready : std_logic;

    signal m_axis_tdata  : std_logic_vector(c_DATA_WIDTH-1 downto 0);
    signal m_axis_tkeep  : std_logic_vector(c_DATA_WIDTH/8-1 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tlast  : std_logic;
    signal m_axis_tready : std_logic := '0';

    -- Measurement state
    signal r_cycles    : natural   := 0;
    signal r_counting  : std_logic := '0';
    signal r_done      : std_logic := '0';
    signal r_out_beats : natural   := 0;
    signal r_pkts_out  : natural   := 0;

    constant c_in_prob  : real := real(G_IN_VALID_PCT)  / 100.0;
    constant c_out_prob : real := real(G_OUT_READY_PCT) / 100.0;

    -- Free-running clock tick, shared by source and sink so that a phase
    -- difference between the two periodic patterns is meaningful.
    signal r_tick     : natural   := 0;
    signal w_src_gate : std_logic := '1';

begin

    p_TICK : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '0' then r_tick <= 0;
            else               r_tick <= r_tick + 1; end if;
        end if;
    end process;

    w_src_gate <= '1' when G_SRC_GO <= 0 else
                  '1' when (r_tick mod (G_SRC_GO + G_SRC_STALL)) < G_SRC_GO else
                  '0';

    p_CLK : process
    begin
        clk <= '0'; wait for c_CLK_PERIOD/2;
        clk <= '1'; wait for c_CLK_PERIOD/2;
    end process;

    u_dut : entity work.gcm_enc
        generic map (
            AES_BITS     => G_AES_BITS,
            ROUND_STYLE  => G_ROUND_STYLE,
            FLOW_STYLE   => G_FLOW_STYLE,
            WRAPPER_KIND => G_WRAPPER_KIND,
            NUM_CORES    => G_NUM_CORES,
            AAD_BEATS    => 0,
            MULT_CYCLES  => G_MULT_CYCLES,
            DATA_WIDTH   => c_DATA_WIDTH
        )
        port map (
            i_clk         => clk,
            i_rstn        => rstn,
            i_key         => i_key,
            i_key_valid   => i_key_valid,
            i_nonce       => i_nonce,
            i_nonce_valid => i_nonce_valid,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tkeep  => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tready => s_axis_tready,
            m_axis_tdata  => m_axis_tdata,
            m_axis_tkeep  => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tlast  => m_axis_tlast,
            m_axis_tready => m_axis_tready
        );

    ----------------------------------------------------------------------------
    -- Sink throttle.  At 100 % this is a constant '1', so the profile sweep can
    -- include the no-backpressure reference without a special case.
    ----------------------------------------------------------------------------
    p_TREADY : process
        variable v_s1 : positive := G_SEED + 4242;
        variable v_s2 : positive := G_SEED * 3 + 7;
        variable v_r  : real;
    begin
        m_axis_tready <= '0';
        loop
            wait until rising_edge(clk);
            if rstn = '0' then
                m_axis_tready <= '0';
            elsif G_BURST_GO > 0 then
                -- Deterministic burst: GO cycles ready, then STALL cycles idle.
                -- Driven off the shared tick so G_SINK_PHASE can slide this
                -- pattern against the source pattern.
                if ((r_tick + G_SINK_PHASE) mod (G_BURST_GO + G_BURST_STALL))
                       < G_BURST_GO then
                    m_axis_tready <= '1';
                else
                    m_axis_tready <= '0';
                end if;
            elsif G_OUT_READY_PCT >= 100 then
                m_axis_tready <= '1';
            else
                uniform(v_s1, v_s2, v_r);
                if v_r < c_out_prob then m_axis_tready <= '1';
                else                     m_axis_tready <= '0'; end if;
            end if;
        end loop;
    end process;

    ----------------------------------------------------------------------------
    -- Measurement.  The window opens on the first accepted input beat and
    -- closes on the TLAST of the last packet, so it spans exactly the work the
    -- core does for this batch, stalls included.
    ----------------------------------------------------------------------------
    p_MEAS : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '0' then
                r_cycles <= 0; r_counting <= '0'; r_done <= '0';
                r_out_beats <= 0; r_pkts_out <= 0;
            else
                if r_counting = '1' then
                    r_cycles <= r_cycles + 1;
                elsif r_done = '0' and s_axis_tvalid = '1' and s_axis_tready = '1' then
                    r_counting <= '1';
                    r_cycles   <= 1;
                end if;

                if m_axis_tvalid = '1' and m_axis_tready = '1' then
                    r_out_beats <= r_out_beats + 1;
                    if m_axis_tlast = '1' then
                        r_pkts_out <= r_pkts_out + 1;
                        if r_pkts_out + 1 >= G_NUM_PACKETS then
                            r_counting <= '0';
                            r_done     <= '1';
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Driver.  Mirrors tb_gcm_enc_src_dense: the next packet's nonce is pulsed
    -- one beat before this packet ends, so the shadow register applies it at
    -- flush and packets stream back to back.  Any idle gap here would be
    -- measured as if the core were slow, which is exactly what must be avoided.
    ----------------------------------------------------------------------------
    p_DRIVE : process
        variable v_s1, v_s2 : positive;
        variable v_r        : real;
        variable v_iv       : unsigned(95 downto 0);
        variable v_off      : integer;
        variable v_l        : line;
        variable v_bits     : real;
        variable v_bpc      : real;

        procedure send_beat(constant d    : in std_logic_vector(127 downto 0);
                            constant last : in std_logic) is
        begin
            s_axis_tdata <= d;
            s_axis_tlast <= last;
            loop
                if G_SRC_GO > 0 then
                    -- Periodic source: valid for GO clocks, idle for STALL.
                    if w_src_gate = '1' then
                        s_axis_tvalid <= '1';
                        wait until rising_edge(clk);
                        exit when s_axis_tready = '1';
                    else
                        s_axis_tvalid <= '0';
                        wait until rising_edge(clk);
                    end if;
                elsif G_IN_VALID_PCT >= 100 then
                    s_axis_tvalid <= '1';
                    wait until rising_edge(clk);
                    exit when s_axis_tready = '1';
                else
                    uniform(v_s1, v_s2, v_r);
                    if v_r < c_in_prob then
                        s_axis_tvalid <= '1';
                        wait until rising_edge(clk);
                        exit when s_axis_tready = '1';
                    else
                        s_axis_tvalid <= '0';
                        wait until rising_edge(clk);
                    end if;
                end if;
            end loop;
        end procedure;

        procedure pulse_iv(constant iv : in std_logic_vector(95 downto 0)) is
        begin
            s_axis_tvalid <= '0';
            i_nonce       <= iv;
            i_nonce_valid <= '1';
            wait until rising_edge(clk);
            i_nonce_valid <= '0';
        end procedure;
    begin
        v_s1 := G_SEED;
        v_s2 := G_SEED * 13 + 1;

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        i_key       <= (others => '0');
        i_key(127 downto 0) <= x"0123456789abcdef0123456789abcdef";
        i_key_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';
        for i in 1 to 4 loop wait until rising_edge(clk); end loop;

        v_iv := unsigned'(x"deadbeefcafebabe11223344");
        pulse_iv(std_logic_vector(v_iv));

        if G_PKT_BEATS >= 2 then v_off := G_PKT_BEATS - 2; else v_off := -1; end if;

        for n in 0 to G_NUM_PACKETS-1 loop
            for i in 1 to 5000 loop
                wait until rising_edge(clk);
                exit when s_axis_tready = '1';
            end loop;
            assert s_axis_tready = '1'
                report "DEADLOCK: packet " & integer'image(n) & " never opened"
                severity failure;

            for b in 0 to G_PKT_BEATS-1 loop
                if b = G_PKT_BEATS-1 then
                    send_beat(std_logic_vector(to_unsigned(n*256 + b, 128)), '1');
                else
                    send_beat(std_logic_vector(to_unsigned(n*256 + b, 128)), '0');
                end if;
                if n < G_NUM_PACKETS-1 and b = v_off then
                    v_iv := v_iv + 1;
                    pulse_iv(std_logic_vector(v_iv));
                end if;
            end loop;
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';

            if n < G_NUM_PACKETS-1 and G_PKT_BEATS < 2 then
                v_iv := v_iv + 1;
                pulse_iv(std_logic_vector(v_iv));
            end if;
        end loop;

        -- Drain
        for i in 1 to 2000000 loop
            wait until rising_edge(clk);
            exit when r_done = '1';
        end loop;

        v_bits := real(G_NUM_PACKETS) * real(G_PKT_BEATS) * 128.0;
        if r_cycles > 0 then v_bpc := v_bits / real(r_cycles); else v_bpc := 0.0; end if;

        report "==== GCM throughput ====";
        report "config      : " & G_WRAPPER_KIND & "/" & G_ROUND_STYLE & "/" & G_FLOW_STYLE
             & "  cores=" & integer'image(G_NUM_CORES)
             & "  mult="  & integer'image(G_MULT_CYCLES);
        report "profile     : pkt=" & integer'image(G_PKT_BEATS) & " beats"
             & "  n="   & integer'image(G_NUM_PACKETS)
             & "  in="  & integer'image(G_IN_VALID_PCT) & "%"
             & "  out=" & integer'image(G_OUT_READY_PCT) & "%"
             & "  burst=" & integer'image(G_BURST_GO) & "/" & integer'image(G_BURST_STALL);
        report "cycles      : " & integer'image(r_cycles);
        report "out beats   : " & integer'image(r_out_beats)
             & " (expected " & integer'image(c_EXP_OUT_BEATS) & ")";

        -- One machine-readable line; the sweep script greps for this prefix.
        write(v_l, string'("CSV,"));
        write(v_l, G_WRAPPER_KIND);                 write(v_l, string'(","));
        write(v_l, G_ROUND_STYLE);                  write(v_l, string'(","));
        write(v_l, G_FLOW_STYLE);                   write(v_l, string'(","));
        write(v_l, G_NUM_CORES);                    write(v_l, string'(","));
        write(v_l, G_MULT_CYCLES);                  write(v_l, string'(","));
        write(v_l, G_PKT_BEATS);                    write(v_l, string'(","));
        write(v_l, G_NUM_PACKETS);                  write(v_l, string'(","));
        write(v_l, G_IN_VALID_PCT);                 write(v_l, string'(","));
        write(v_l, G_OUT_READY_PCT);                write(v_l, string'(","));
        write(v_l, r_cycles);                       write(v_l, string'(","));
        write(v_l, r_out_beats);                    write(v_l, string'(","));
        write(v_l, c_EXP_OUT_BEATS);
        -- New fields go at the END so the sweep script's column positions for
        -- cycles / out_beats / exp_beats stay valid.
        write(v_l, string'(","));                   write(v_l, G_SRC_GO);
        write(v_l, string'(","));                   write(v_l, G_SRC_STALL);
        write(v_l, string'(","));                   write(v_l, G_SINK_PHASE);
        writeline(output, v_l);

        if r_done = '1' and r_out_beats = c_EXP_OUT_BEATS then
            report "RESULT: PASS";
        else
            report "RESULT: FAIL (drain timeout or wrong beat count)" severity failure;
        end if;
        finish;
    end process;

end architecture;
