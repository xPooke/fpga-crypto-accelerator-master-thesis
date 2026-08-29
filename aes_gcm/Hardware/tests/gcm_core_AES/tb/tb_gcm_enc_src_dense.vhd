----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_gcm_enc_src_dense
-- Module Name   : tb_gcm_enc_src_dense - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Dense back-to-back streaming stress on the encryptor: packets issued
--                 with no idle cycles, output scoreboarded.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use std.textio.all;

entity tb_gcm_enc_src_dense is
    generic (
        G_NUM_PACKETS   : integer := 100;
        G_NUM_CORES     : integer := 4;
        G_AES_BITS      : integer := 128;
        G_WRAPPER_KIND  : string  := "MULTICORE";  -- "MULTICORE" or "UNROLLED"
        G_IN_VALID_PCT  : integer := 80;   -- slave TVALID duty
        G_OUT_READY_PCT : integer := 80;   -- master TREADY duty
        G_SEED          : positive := 1
    );
end entity;

architecture sim of tb_gcm_enc_src_dense is

    constant c_CLK_PERIOD : time    := 5 ns;
    constant c_DATA_WIDTH : integer := 128;

    signal clk           : std_logic := '0';
    signal rstn          : std_logic := '0';

    signal i_key         : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '0');
    signal i_key_valid   : std_logic := '0';
    signal i_nonce       : std_logic_vector(95 downto 0)   := (others => '0');
    signal i_nonce_valid : std_logic := '0';

    signal s_axis_tdata  : std_logic_vector(c_DATA_WIDTH-1 downto 0)   := (others => '0');
    signal s_axis_tkeep  : std_logic_vector(c_DATA_WIDTH/8-1 downto 0) := (others => '1');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tready : std_logic;

    signal m_axis_tdata  : std_logic_vector(c_DATA_WIDTH-1 downto 0);
    signal m_axis_tkeep  : std_logic_vector(c_DATA_WIDTH/8-1 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tlast  : std_logic;
    signal m_axis_tready : std_logic := '0';

    -- Size table (in 128-bit beats) and the random sizes chosen per packet.
    type t_sizes is array (0 to 5) of integer;
    constant c_sizes : t_sizes := (4, 8, 16, 32, 64, 80);

    type t_size_arr is array (0 to G_NUM_PACKETS-1) of integer;
    shared variable sv_size : t_size_arr := (others => 0);

    -- Sink bookkeeping (driven only by p_SINK; read by p_DRIVE at the end)
    shared variable sv_pkts_done : integer := 0;   -- packets fully emitted (TLAST seen)
    shared variable sv_cur_beats : integer := 0;   -- beats in the in-progress packet
    shared variable sv_mismatch  : integer := 0;   -- packets with wrong beat count

    constant c_in_prob  : real := real(G_IN_VALID_PCT)  / 100.0;
    constant c_out_prob : real := real(G_OUT_READY_PCT) / 100.0;

begin

    p_CLK : process
    begin
        clk <= '0';
        wait for c_CLK_PERIOD / 2;
        clk <= '1';
        wait for c_CLK_PERIOD / 2;
    end process;

    u_dut : entity work.gcm_enc
        generic map (
            AES_BITS     => G_AES_BITS,
            ROUND_STYLE  => "LUT",
            WRAPPER_KIND => G_WRAPPER_KIND,
            NUM_CORES    => G_NUM_CORES,
            AAD_BEATS    => 0,
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
    -- Master TREADY random throttle
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
            else
                uniform(v_s1, v_s2, v_r);
                if v_r < c_out_prob then m_axis_tready <= '1';
                else                     m_axis_tready <= '0'; end if;
            end if;
        end loop;
    end process;

    ----------------------------------------------------------------------------
    -- Output sink: count TLAST-delimited packets and per-packet beat counts.
    ----------------------------------------------------------------------------
    p_SINK : process(clk)
        variable v_l : line;
    begin
        if rising_edge(clk) then
            if rstn = '1' and m_axis_tvalid = '1' and m_axis_tready = '1' then
                sv_cur_beats := sv_cur_beats + 1;
                if m_axis_tlast = '1' then
                    -- Expected: size+1 (CT beats + ICV), AAD=0.
                    if sv_pkts_done < G_NUM_PACKETS then
                        if sv_cur_beats /= sv_size(sv_pkts_done) + 1 then
                            sv_mismatch := sv_mismatch + 1;
                            if sv_mismatch <= 6 then
                                write(v_l, string'("  mismatch pkt "));
                                write(v_l, sv_pkts_done);
                                write(v_l, string'(": got "));
                                write(v_l, sv_cur_beats);
                                write(v_l, string'(" beats, expected "));
                                write(v_l, sv_size(sv_pkts_done) + 1);
                                writeline(output, v_l);
                            end if;
                        end if;
                    end if;
                    sv_pkts_done := sv_pkts_done + 1;
                    sv_cur_beats := 0;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Driver: dense streaming with IV pulsed around each packet boundary.
    ----------------------------------------------------------------------------
    p_DRIVE : process
        variable v_s1, v_s2 : positive;
        variable v_r        : real;
        variable v_idx      : integer;
        variable v_off      : integer;
        variable v_iv       : unsigned(95 downto 0);

        -- Present one beat with random TVALID throttle; hold until accepted.
        procedure send_beat(constant d : in std_logic_vector(127 downto 0);
                            constant last : in std_logic) is
        begin
            s_axis_tdata <= d;
            s_axis_tlast <= last;
            loop
                uniform(v_s1, v_s2, v_r);
                if v_r < c_in_prob then
                    s_axis_tvalid <= '1';
                    wait until rising_edge(clk);
                    exit when s_axis_tready = '1';
                else
                    s_axis_tvalid <= '0';
                    wait until rising_edge(clk);
                end if;
            end loop;
        end procedure;

        procedure pulse_iv(constant iv : in std_logic_vector(95 downto 0)) is
        begin
            -- Drop TVALID during the IV pulse so the just-accepted beat is not
            -- re-accepted on this extra cycle (TB hygiene, not a DUT effect).
            s_axis_tvalid <= '0';
            i_nonce       <= iv;
            i_nonce_valid <= '1';
            wait until rising_edge(clk);
            i_nonce_valid <= '0';
        end procedure;
    begin
        v_s1 := G_SEED;
        v_s2 := G_SEED * 13 + 1;

        -- Pick sizes
        for n in 0 to G_NUM_PACKETS-1 loop
            uniform(v_s1, v_s2, v_r);
            v_idx := integer(floor(v_r * real(c_sizes'length)));
            if v_idx > c_sizes'high then v_idx := c_sizes'high; end if;
            sv_size(n) := c_sizes(v_idx);
        end loop;

        -- Reset
        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        -- Key once (the LSBs hold the key; the rest of the blob is 0)
        i_key <= x"0123456789abcdef0123456789abcdef";
        i_key_valid         <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';
        for i in 1 to 4 loop wait until rising_edge(clk); end loop;

        -- IV for packet 0 (idle)
        v_iv := unsigned'(x"deadbeefcafebabe11223344");
        pulse_iv(std_logic_vector(v_iv));

        -- Stream all packets dense. The NEXT packet's IV is pulsed mid-packet
        -- (S_RUN -> shadow) at a random beat near THIS packet's tail, modelling
        -- an upstream that issues the IV just before packet end. Shadow applies
        -- at flush, so packet N+1 starts back-to-back with no idle gap.
        for n in 0 to G_NUM_PACKETS-1 loop
            -- Wait for this packet's pipeline to open
            for i in 1 to 2000 loop
                wait until rising_edge(clk);
                exit when s_axis_tready = '1';
            end loop;
            assert s_axis_tready = '1'
                report "DEADLOCK: packet " & integer'image(n)
                     & " pipeline never opened (IV likely swallowed)"
                severity failure;

            -- Random trigger beat in the tail (but not the very last beat, so
            -- the pulse lands in S_RUN -> shadow). For size 1 there is no tail.
            if sv_size(n) >= 2 then
                uniform(v_s1, v_s2, v_r);
                -- offset 1..3 beats before the last beat
                v_off := 1 + integer(floor(v_r * 3.0));
                v_off := sv_size(n) - 1 - v_off;
                if v_off < 0 then v_off := 0; end if;
            else
                v_off := -1;   -- no mid-packet trigger possible
            end if;

            -- Drive the packet's beats; pulse next IV right after the trigger beat
            for b in 0 to sv_size(n)-1 loop
                if b = sv_size(n)-1 then
                    send_beat(std_logic_vector(to_unsigned(n*256 + b, 128)), '1');
                else
                    send_beat(std_logic_vector(to_unsigned(n*256 + b, 128)), '0');
                end if;
                if n < G_NUM_PACKETS-1 and b = v_off then
                    v_iv := v_iv + 1;
                    pulse_iv(std_logic_vector(v_iv));   -- 1-cycle, S_RUN -> shadow
                end if;
            end loop;
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';

            -- Fallback: size-1 packet has no mid-packet slot; pulse next IV now.
            if n < G_NUM_PACKETS-1 and sv_size(n) < 2 then
                v_iv := v_iv + 1;
                pulse_iv(std_logic_vector(v_iv));
            end if;
        end loop;

        -- Wait for the sink to drain all packets
        for i in 1 to 20000 loop
            wait until rising_edge(clk);
            exit when sv_pkts_done >= G_NUM_PACKETS;
        end loop;

        report "==== Dense stress result ====";
        report "Packets emitted : " & integer'image(sv_pkts_done)
             & " / " & integer'image(G_NUM_PACKETS);
        report "Beat-count mismatches : " & integer'image(sv_mismatch);

        if sv_pkts_done = G_NUM_PACKETS and sv_mismatch = 0 then
            report "PASS: all packets streamed dense with correct beat counts; no IV swallowed";
        else
            report "FAIL: deadlock or structural corruption under dense streaming"
                severity failure;
        end if;

        wait for 20 * c_CLK_PERIOD;
        finish(0);
    end process;

    ----------------------------------------------------------------------------
    -- Watchdog
    ----------------------------------------------------------------------------
    p_TIMEOUT : process
    begin
        wait for 5 ms;
        report "Hard timeout (consistent with a deadlock)" severity failure;
        finish(1);
    end process;

end architecture;
