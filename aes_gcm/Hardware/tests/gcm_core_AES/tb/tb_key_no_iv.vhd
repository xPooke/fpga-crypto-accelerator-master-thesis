----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_key_no_iv
-- Module Name   : tb_key_no_iv - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Negative test: a mid-packet key change WITHOUT a new IV. The key is
--                 staged into the shadow register and applied at the flush, after which
--                 the IV-reuse guard clears r_have_nonce - so the wrapper must go quiet
--                 rather than encrypt under a reused IV.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_key_no_iv is
    generic (
        G_WRAPPER_KIND : string := "MULTICORE"
    );
end entity;

architecture sim of tb_key_no_iv is

    constant c_CLK_PERIOD : time := 5 ns;

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';

    signal i_key         : std_logic_vector(127 downto 0) := (others => '0');
    signal i_key_valid   : std_logic := '0';
    signal i_nonce       : std_logic_vector(95 downto 0)  := (others => '0');
    signal i_nonce_valid : std_logic := '0';

    -- The wrapper key port is 256 bits wide, while the stimulus below is
    -- a 128-bit key; widened here.
    signal w_key_blob : std_logic_vector(255 downto 0) := (others => '0');

    signal s_axis_tdata  : std_logic_vector(127 downto 0) := (others => '0');
    signal s_axis_tkeep  : std_logic_vector(15 downto 0)  := (others => '1');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tready : std_logic;

    signal m_axis_tdata  : std_logic_vector(127 downto 0);
    signal m_axis_tkeep  : std_logic_vector(15 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tlast  : std_logic;
    signal m_axis_tready : std_logic := '1';

    signal o_H         : std_logic_vector(127 downto 0);
    signal o_H_valid   : std_logic;
    signal o_E_k       : std_logic_vector(127 downto 0);
    signal o_E_k_valid : std_logic;

    signal r_h_pulses   : integer := 0;
    signal r_ek_pulses  : integer := 0;
    signal r_ct_beats   : integer := 0;   -- accepted CT beats (m side)
    signal r_pt_accepts : integer := 0;   -- accepted PT beats (s side)

begin

    w_key_blob(127 downto 0) <= i_key;

    p_CLK : process
    begin
        clk <= '0';
        wait for c_CLK_PERIOD / 2;
        clk <= '1';
        wait for c_CLK_PERIOD / 2;
    end process;

    gen_mc : if G_WRAPPER_KIND = "MULTICORE" generate
        u_dut : entity work.AES_multicore_wrapper
            generic map (AES_BITS => 128, ROUND_STYLE => "LUT", NUM_CORES => 4)
            port map (
                i_clk => clk, i_rstn => rstn,
                i_key => w_key_blob, i_key_valid => i_key_valid,
                i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,
                s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid,
                s_axis_tready => s_axis_tready, s_axis_tlast => s_axis_tlast,
                s_axis_tkeep => s_axis_tkeep,
                m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid,
                m_axis_tready => m_axis_tready, m_axis_tlast => m_axis_tlast,
                m_axis_tkeep => m_axis_tkeep,
                o_H => o_H, o_H_valid => o_H_valid,
                o_E_k => o_E_k, o_E_k_valid => o_E_k_valid);
    end generate;

    gen_up : if G_WRAPPER_KIND = "UNROLLED" generate
        u_dut : entity work.AES_pipelined_wrapper
            generic map (AES_BITS => 128, ROUND_STYLE => "LUT", FLOW_STYLE => "GLOBAL")
            port map (
                i_clk => clk, i_rstn => rstn,
                i_key => w_key_blob, i_key_valid => i_key_valid,
                i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,
                s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid,
                s_axis_tready => s_axis_tready, s_axis_tlast => s_axis_tlast,
                s_axis_tkeep => s_axis_tkeep,
                m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid,
                m_axis_tready => m_axis_tready, m_axis_tlast => m_axis_tlast,
                m_axis_tkeep => m_axis_tkeep,
                o_H => o_H, o_H_valid => o_H_valid,
                o_E_k => o_E_k, o_E_k_valid => o_E_k_valid);
    end generate;

    p_OBS : process(clk)
    begin
        if rising_edge(clk) then
            if o_H_valid = '1' then
                r_h_pulses <= r_h_pulses + 1;
            end if;
            if o_E_k_valid = '1' then
                r_ek_pulses <= r_ek_pulses + 1;
            end if;
            if m_axis_tvalid = '1' and m_axis_tready = '1' then
                r_ct_beats <= r_ct_beats + 1;
            end if;
            if s_axis_tvalid = '1' and s_axis_tready = '1' then
                r_pt_accepts <= r_pt_accepts + 1;
            end if;
        end if;
    end process;

    p_STIM : process
        variable v_h_before, v_ek_before : integer;
        variable v_ct_before, v_pt_before : integer;
        variable v_h_window : integer;

        procedure send_beat(constant byte0 : in std_logic_vector(7 downto 0);
                            constant last  : in std_logic) is
        begin
            s_axis_tdata  <= (others => '0');
            s_axis_tdata(7 downto 0) <= byte0;
            s_axis_tlast  <= last;
            s_axis_tvalid <= '1';
            wait until rising_edge(clk) and s_axis_tready = '1';
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';
        end procedure;

    begin
        report "==== tb_key_no_iv (" & G_WRAPPER_KIND & ") ====";

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- Packet 1: key1 + nonce1, 3 PT beats; key2 pulsed mid-packet (shadow)
        ------------------------------------------------------------------------
        i_key       <= x"000102030405060708090a0b0c0d0e0f";
        i_key_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';
        for i in 1 to 4 loop wait until rising_edge(clk); end loop;

        i_nonce       <= x"cafebabe0000000000000001";
        i_nonce_valid <= '1';
        wait until rising_edge(clk);
        i_nonce_valid <= '0';

        send_beat(x"01", '0');

        -- mid-packet key change, NO new nonce
        i_key       <= x"ffeeddccbbaa99887766554433221100";
        i_key_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';
        report "key2 pulsed mid-packet (no new nonce will follow)";

        send_beat(x"02", '0');
        send_beat(x"03", '1');

        -- wait for packet 1's last CT beat to drain
        for i in 1 to 100 loop
            exit when r_ct_beats >= 3;
            wait until rising_edge(clk);
        end loop;
        assert r_ct_beats = 3
            report "packet 1: expected 3 CT beats, got "
                   & integer'image(r_ct_beats) severity failure;
        report "packet 1 drained (3 CT beats); rekey flush has fired";

        ------------------------------------------------------------------------
        -- The no-nonce window: 1000 cycles of mandated silence.
        -- Offer a PT beat the whole time -- it must NOT be consumed.
        ------------------------------------------------------------------------
        v_h_before  := r_h_pulses;
        v_ek_before := r_ek_pulses;
        v_ct_before := r_ct_beats;
        v_pt_before := r_pt_accepts;

        s_axis_tdata  <= (others => '0');
        s_axis_tdata(7 downto 0) <= x"b1";
        s_axis_tlast  <= '0';
        s_axis_tvalid <= '1';

        for i in 1 to 1000 loop wait until rising_edge(clk); end loop;
        s_axis_tvalid <= '0';

        v_h_window := r_h_pulses - v_h_before;
        report "no-nonce window: H+" & integer'image(v_h_window)
             & " EK+" & integer'image(r_ek_pulses - v_ek_before)
             & " CT+" & integer'image(r_ct_beats - v_ct_before)
             & " PTacc+" & integer'image(r_pt_accepts - v_pt_before);

        assert r_ek_pulses = v_ek_before
            report "FAIL: EK dispatched without a fresh nonce -- "
                 & "old nonce reused with the new key" severity failure;
        assert r_ct_beats = v_ct_before
            report "FAIL: CT emitted during the no-nonce window" severity failure;
        assert r_pt_accepts = v_pt_before
            report "FAIL: PT consumed during the no-nonce window" severity failure;
        assert v_h_window <= 1
            report "FAIL: H recomputed more than once in the window" severity failure;
        report "window PASS: wrapper stayed quiet without a nonce";

        ------------------------------------------------------------------------
        -- Fresh nonce: packet 2 must run with key2 (H recompute total = 2)
        ------------------------------------------------------------------------
        i_nonce       <= x"cafebabe0000000000000002";
        i_nonce_valid <= '1';
        wait until rising_edge(clk);
        i_nonce_valid <= '0';

        for i in 1 to 1500 loop
            exit when r_ek_pulses >= 2;
            wait until rising_edge(clk);
        end loop;
        assert r_ek_pulses = 2
            report "FAIL: EK#2 never fired after the fresh nonce" severity failure;
        assert r_h_pulses = 2
            report "FAIL: packet 2 EK fired with H pulses = "
                 & integer'image(r_h_pulses)
                 & " (expected 2 -- H must be recomputed for key2)" severity failure;

        send_beat(x"b1", '0');
        send_beat(x"b2", '1');

        for i in 1 to 100 loop
            exit when r_ct_beats >= 5;
            wait until rising_edge(clk);
        end loop;
        assert r_ct_beats = 5
            report "FAIL: packet 2 expected 2 CT beats (total 5), got total "
                   & integer'image(r_ct_beats) severity failure;

        report "==== tb_key_no_iv (" & G_WRAPPER_KIND & "): ALL PASS ====";
        finish(0);
    end process;

    p_TIMEOUT : process
    begin
        wait for 200 us;
        report "Hard timeout" severity failure;
        finish(1);
    end process;

end architecture;
