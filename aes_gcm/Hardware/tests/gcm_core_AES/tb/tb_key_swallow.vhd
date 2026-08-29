----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_key_swallow
-- Module Name   : tb_key_swallow - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : A key pulse landing on the exact packet-end flush cycle must not be
--                 swallowed. That window once lost an IV pulse to if/elsif mutual
--                 exclusion; this checks the same window for i_key_valid.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_key_swallow is
    generic (
        G_WRAPPER_KIND : string := "MULTICORE"
    );
end entity;

architecture sim of tb_key_swallow is

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
    signal m_axis_tready : std_logic := '0';

    signal o_H         : std_logic_vector(127 downto 0);
    signal o_H_valid   : std_logic;
    signal o_E_k       : std_logic_vector(127 downto 0);
    signal o_E_k_valid : std_logic;

    signal r_h_pulses  : integer := 0;
    signal r_ek_pulses : integer := 0;
    signal r_last_H    : std_logic_vector(127 downto 0) := (others => '0');

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
            generic map (
                AES_BITS    => 128,
                ROUND_STYLE => "LUT",
                NUM_CORES   => 4
            )
            port map (
                i_clk         => clk,
                i_rstn        => rstn,
                i_key         => w_key_blob,
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
    end generate;

    gen_up : if G_WRAPPER_KIND = "UNROLLED" generate
        u_dut : entity work.AES_pipelined_wrapper
            generic map (
                AES_BITS    => 128,
                ROUND_STYLE => "LUT",
                FLOW_STYLE  => "GLOBAL"
            )
            port map (
                i_clk         => clk,
                i_rstn        => rstn,
                i_key         => w_key_blob,
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
    end generate;

    -- Pulse counters: every applied key forces an H recompute, so the H
    -- counter at the moment of an EK pulse identifies the key in use.
    p_OBS : process(clk)
    begin
        if rising_edge(clk) then
            if o_H_valid = '1' then
                r_h_pulses <= r_h_pulses + 1;
                r_last_H   <= o_H;
            end if;
            if o_E_k_valid = '1' then
                r_ek_pulses <= r_ek_pulses + 1;
            end if;
        end if;
    end process;

    p_STIM : process
        variable v_h_at_ek : integer;

        -- Send one TLAST PT beat but hold m_axis_tready=0 so the CT beat
        -- stalls on the master side and the flush is armed.
        procedure arm_flush(constant byte0 : in std_logic_vector(7 downto 0)) is
        begin
            -- wait for the CT pipeline to accept input
            for i in 1 to 600 loop
                exit when s_axis_tready = '1';
                wait until rising_edge(clk);
            end loop;
            assert s_axis_tready = '1'
                report "arm_flush: s_axis_tready timeout" severity failure;

            -- NOTE: the wrapper CT path is a pass-through (the PT beat is
            -- accepted on the same cycle its CT beat is accepted), so the
            -- beat stays offered until the release cycle fires the flush.
            m_axis_tready <= '0';
            s_axis_tdata  <= (others => '0');
            s_axis_tdata(7 downto 0) <= byte0;
            s_axis_tlast  <= '1';
            s_axis_tvalid <= '1';

            -- wait until the CT beat is offered (flush armed)
            for i in 1 to 200 loop
                exit when m_axis_tvalid = '1';
                wait until rising_edge(clk);
            end loop;
            assert m_axis_tvalid = '1'
                report "arm_flush: m_axis_tvalid timeout" severity failure;
        end procedure;

        procedure wait_ek(constant n : in integer; constant tag : in string) is
        begin
            for i in 1 to 1500 loop
                exit when r_ek_pulses >= n;
                wait until rising_edge(clk);
            end loop;
            assert r_ek_pulses >= n
                report tag & ": EK pulse #" & integer'image(n)
                       & " never fired (deadlock)" severity failure;
        end procedure;

    begin
        report "==== tb_key_swallow (" & G_WRAPPER_KIND & ") ====";

        rstn          <= '0';
        m_axis_tready <= '1';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- Packet 1: key1 + IV1 at idle (reference behavior: H1 then EK1)
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

        wait_ek(1, "packet 1");
        assert r_h_pulses = 1
            report "packet 1: expected exactly 1 H pulse, got "
                   & integer'image(r_h_pulses) severity failure;
        report "packet 1 running: H=1, EK=1";

        ------------------------------------------------------------------------
        -- S1: key2 ALONE on the flush cycle of packet 1
        ------------------------------------------------------------------------
        arm_flush(x"a1");

        -- the coincidence: release the CT beat AND pulse key2 the same cycle
        m_axis_tready <= '1';
        i_key         <= x"ffeeddccbbaa99887766554433221100";
        i_key_valid   <= '1';
        wait until rising_edge(clk);
        i_key_valid   <= '0';
        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';
        report "S1: key2 pulsed on flush cycle";

        -- a few idle cycles, then the IV that starts packet 2
        for i in 1 to 10 loop wait until rising_edge(clk); end loop;
        i_nonce       <= x"cafebabe0000000000000002";
        i_nonce_valid <= '1';
        wait until rising_edge(clk);
        i_nonce_valid <= '0';

        wait_ek(2, "S1");
        v_h_at_ek := r_h_pulses;
        report "S1: EK#2 fired with H pulses = " & integer'image(v_h_at_ek);
        assert v_h_at_ek = 2
            report "S1 FAIL: packet 2 started WITHOUT an H recompute -- "
                 & "key2 was swallowed/orphaned on the flush cycle "
                 & "(packet 2 is running with the OLD key)"
            severity failure;
        report "S1 PASS: packet 2 uses key2 (fresh H before EK)";

        ------------------------------------------------------------------------
        -- S2: key3 AND nonce3 BOTH on the flush cycle of packet 2
        ------------------------------------------------------------------------
        arm_flush(x"a2");

        m_axis_tready <= '1';
        i_key         <= x"0123456789abcdef0123456789abcdef";
        i_key_valid   <= '1';
        i_nonce       <= x"cafebabe0000000000000003";
        i_nonce_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid   <= '0';
        i_nonce_valid <= '0';
        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';
        report "S2: key3 + nonce3 pulsed on flush cycle";

        wait_ek(3, "S2");
        v_h_at_ek := r_h_pulses;
        report "S2: EK#3 fired with H pulses = " & integer'image(v_h_at_ek);
        assert v_h_at_ek = 3
            report "S2 FAIL: packet 3 started WITHOUT an H recompute -- "
                 & "the coincident nonce was honored but key3 was orphaned "
                 & "(packet 3 is running with the OLD key)"
            severity failure;
        report "S2 PASS: packet 3 uses key3 (fresh H before EK)";

        ------------------------------------------------------------------------
        -- Drain packet 3 so the run ends in a clean state
        ------------------------------------------------------------------------
        arm_flush(x"a3");
        m_axis_tready <= '1';
        wait until rising_edge(clk);
        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';

        report "==== tb_key_swallow (" & G_WRAPPER_KIND & "): ALL PASS ====";
        finish(0);
    end process;

    p_TIMEOUT : process
    begin
        wait for 100 us;
        report "Hard timeout" severity failure;
        finish(1);
    end process;

end architecture;
