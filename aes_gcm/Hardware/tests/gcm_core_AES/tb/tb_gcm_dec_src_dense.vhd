----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_gcm_dec_src_dense
-- Module Name   : tb_gcm_dec_src_dense - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Dense back-to-back streaming stress on the decryptor: packets issued
--                 with no idle cycles, PT and the auth verdict checked.
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

entity tb_gcm_dec_src_dense is
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

architecture sim of tb_gcm_dec_src_dense is

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

    signal o_auth_ok     : std_logic;
    signal o_dec_done    : std_logic;

    -- Size table (in 128-bit CT beats) and the random sizes per packet.
    type t_sizes is array (0 to 5) of integer;
    constant c_sizes : t_sizes := (4, 8, 16, 32, 64, 80);

    type t_size_arr is array (0 to G_NUM_PACKETS-1) of integer;
    shared variable sv_size : t_size_arr := (others => 0);

    -- Sink bookkeeping
    shared variable sv_pkts_done : integer := 0;   -- output packets (TLAST seen)
    shared variable sv_cur_beats : integer := 0;
    shared variable sv_mismatch  : integer := 0;

    -- Side-band bookkeeping
    shared variable sv_done_pulses : integer := 0; -- o_dec_done count
    shared variable sv_auth_pass   : integer := 0; -- dec_done with auth_ok='1' (must stay 0)

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

    u_dut : entity work.gcm_dec
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
            m_axis_tready => m_axis_tready,
            o_auth_ok     => o_auth_ok,
            o_dec_done    => o_dec_done
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
    -- Output sink: per-packet beat counts. Expected: `size` PT beats (AAD=0;
    -- the ICV beat is consumed by the Tag_Verifier, not forwarded).
    ----------------------------------------------------------------------------
    p_SINK : process(clk)
        variable v_l : line;
    begin
        if rising_edge(clk) then
            if rstn = '1' and m_axis_tvalid = '1' and m_axis_tready = '1' then
                sv_cur_beats := sv_cur_beats + 1;
                if m_axis_tlast = '1' then
                    if sv_pkts_done < G_NUM_PACKETS then
                        if sv_cur_beats /= sv_size(sv_pkts_done) then
                            sv_mismatch := sv_mismatch + 1;
                            if sv_mismatch <= 6 then
                                write(v_l, string'("  mismatch pkt "));
                                write(v_l, sv_pkts_done);
                                write(v_l, string'(": got "));
                                write(v_l, sv_cur_beats);
                                write(v_l, string'(" beats, expected "));
                                write(v_l, sv_size(sv_pkts_done));
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
    -- Auth side-band. o_dec_done is a LEVEL held while the last beat is being
    -- offered ("synchronized with TLAST handshake" -- see axis_mux_dec), so it
    -- must be sampled exactly on the last-beat handshake, not counted per
    -- cycle. There it must be '1' on every packet; with a garbage ICV the
    -- verdict must be auth_ok='0' every time.
    ----------------------------------------------------------------------------
    p_AUTH : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '1' and m_axis_tvalid = '1' and m_axis_tready = '1'
               and m_axis_tlast = '1' then
                assert o_dec_done = '1'
                    report "dec_done not asserted on the TLAST handshake"
                    severity failure;
                sv_done_pulses := sv_done_pulses + 1;
                if o_auth_ok = '1' then
                    sv_auth_pass := sv_auth_pass + 1;
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
            -- TB hygiene: drop TVALID during the IV pulse so the just-accepted
            -- beat is not re-accepted on this extra cycle.
            s_axis_tvalid <= '0';
            i_nonce       <= iv;
            i_nonce_valid <= '1';
            wait until rising_edge(clk);
            i_nonce_valid <= '0';
        end procedure;
    begin
        v_s1 := G_SEED;
        v_s2 := G_SEED * 13 + 1;

        for n in 0 to G_NUM_PACKETS-1 loop
            uniform(v_s1, v_s2, v_r);
            v_idx := integer(floor(v_r * real(c_sizes'length)));
            if v_idx > c_sizes'high then v_idx := c_sizes'high; end if;
            sv_size(n) := c_sizes(v_idx);
        end loop;

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        i_key <= x"0123456789abcdef0123456789abcdef";
        i_key_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';
        for i in 1 to 4 loop wait until rising_edge(clk); end loop;

        v_iv := unsigned'(x"deadbeefcafebabe11223344");
        pulse_iv(std_logic_vector(v_iv));

        -- Stream all packets dense: size CT beats + 1 garbage ICV beat (TLAST).
        -- The NEXT packet's IV is pulsed near THIS packet's tail.
        for n in 0 to G_NUM_PACKETS-1 loop
            for i in 1 to 2000 loop
                wait until rising_edge(clk);
                exit when s_axis_tready = '1';
            end loop;
            assert s_axis_tready = '1'
                report "DEADLOCK: packet " & integer'image(n)
                     & " pipeline never opened (IV likely swallowed)"
                severity failure;

            -- Random IV-trigger beat near the tail (within the CT body).
            uniform(v_s1, v_s2, v_r);
            v_off := 1 + integer(floor(v_r * 3.0));
            v_off := sv_size(n) - 1 - v_off;
            if v_off < 0 then v_off := 0; end if;

            -- CT beats
            for b in 0 to sv_size(n)-1 loop
                send_beat(std_logic_vector(to_unsigned(n*256 + b, 128)), '0');
                if n < G_NUM_PACKETS-1 and b = v_off then
                    v_iv := v_iv + 1;
                    pulse_iv(std_logic_vector(v_iv));
                end if;
            end loop;
            -- garbage ICV beat with TLAST
            send_beat(x"badc0ffee0ddf00dbadc0ffee0ddf00d", '1');
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';
        end loop;

        -- Drain
        for i in 1 to 40000 loop
            wait until rising_edge(clk);
            exit when sv_pkts_done >= G_NUM_PACKETS
                      and sv_done_pulses >= G_NUM_PACKETS;
        end loop;

        report "==== Dense dec stress result ====";
        report "Packets emitted   : " & integer'image(sv_pkts_done)
             & " / " & integer'image(G_NUM_PACKETS);
        report "Beat mismatches   : " & integer'image(sv_mismatch);
        report "dec_done pulses   : " & integer'image(sv_done_pulses);
        report "false auth passes : " & integer'image(sv_auth_pass);

        if sv_pkts_done = G_NUM_PACKETS and sv_mismatch = 0
           and sv_done_pulses = G_NUM_PACKETS and sv_auth_pass = 0 then
            report "PASS: dec streamed dense, all tags verified (and rejected) per packet";
        else
            report "FAIL: deadlock, beat corruption, or Tag_Verifier missed packets"
                severity failure;
        end if;

        wait for 20 * c_CLK_PERIOD;
        finish(0);
    end process;

    p_TIMEOUT : process
    begin
        wait for 5 ms;
        report "Hard timeout (consistent with a deadlock)" severity failure;
        finish(1);
    end process;

end architecture;
