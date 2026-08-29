----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_key_idle_race
-- Module Name   : tb_key_idle_race - tb
-- Tool Version  : GHDL (--std=08 -fsynopsys -frelaxed)
--
-- Description   : Targeted reproducer for the one-cycle S_IDLE re-key race in
--                 AES_multicore_wrapper. Scenario: a packet ends (flush), the
--                 next packet's IV is already staged (shadow), and i_key_valid
--                 pulses exactly in the single S_IDLE cycle between packets.
--                 The new-key pulse then overlaps the first S_RUN cycle while
--                 the dispatch enable still reflects the previous key, so the
--                 wrapper starts one block with half-reloaded round keys; that
--                 garbage block is later mis-captured as H and the true H of
--                 the new key as EK. The test drives the exact window
--                 deterministically and compares o_H / o_E_k against the
--                 reference model values (alg_aes256.py) for the new key:
--                 a design with the race FAILS both checks, a design that
--                 suppresses dispatch on the new-key cycle PASSES.
--                 Part of the run_tests.sh regression.
--
-- Dependencies  : work.AES_multicore_wrapper
--
-- Revision      :
--   0.01 - Aug 2026 - File Created
--   0.02 - Aug 2026 - Wired into run_tests.sh as a permanent regression
--                     test alongside the dispatch-gate fix
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_key_idle_race is
end entity;

architecture tb of tb_key_idle_race is

    constant c_CLK : time := 10 ns;

    -- Keys and IVs (bytes 00..1f / 20..3f; IVs differ in the low word)
    constant c_KEY1 : std_logic_vector(255 downto 0) :=
        x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    constant c_KEY2 : std_logic_vector(255 downto 0) :=
        x"202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f";
    constant c_IV1  : std_logic_vector(95 downto 0) := x"aaaaaaaabbbbbbbb00000001";
    constant c_IV2  : std_logic_vector(95 downto 0) := x"aaaaaaaabbbbbbbb00000002";

    -- Reference values from aes_gcm/Software/Python/alg_aes256.py:
    --   H  = AES_K(0^128), EK = AES_K(IV || 0x00000001)
    constant c_H1  : std_logic_vector(127 downto 0) := x"f29000b62a499fd0a9f39a6add2e7780";
    constant c_EK1 : std_logic_vector(127 downto 0) := x"6203980781406ba210a1a8e7e15ed469";
    constant c_H2  : std_logic_vector(127 downto 0) := x"f34744ebcd337f209c19e3ac13d82dec";
    constant c_EK2 : std_logic_vector(127 downto 0) := x"0926de502c78f51a0934282de1582298";

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';

    signal i_key         : std_logic_vector(255 downto 0) := (others => '0');
    signal i_key_valid   : std_logic := '0';
    signal i_nonce       : std_logic_vector(95 downto 0)  := (others => '0');
    signal i_nonce_valid : std_logic := '0';

    signal s_axis_tdata  : std_logic_vector(127 downto 0) := (others => '0');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tready : std_logic;
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tkeep  : std_logic_vector(15 downto 0)  := (others => '1');

    signal m_axis_tdata  : std_logic_vector(127 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '1';
    signal m_axis_tlast  : std_logic;
    signal m_axis_tkeep  : std_logic_vector(15 downto 0);

    signal o_H         : std_logic_vector(127 downto 0);
    signal o_H_valid   : std_logic;
    signal o_E_k       : std_logic_vector(127 downto 0);
    signal o_E_k_valid : std_logic;
    signal o_h_stale   : std_logic;
    signal o_in_proc   : std_logic;

    signal r_errors : integer := 0;

begin

    u_dut : entity work.AES_multicore_wrapper
        generic map (
            AES_BITS    => 256,
            ROUND_STYLE => "LUT",
            NUM_CORES   => 4
        )
        port map (
            i_clk         => clk,
            i_rstn        => rstn,
            i_key         => i_key,
            i_key_valid   => i_key_valid,
            i_nonce       => i_nonce,
            i_nonce_valid => i_nonce_valid,
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
            o_E_k_valid   => o_E_k_valid,
            o_h_stale     => o_h_stale,
            o_encryption_in_proc => o_in_proc
        );

    clk <= not clk after c_CLK / 2;

    p_STIM : process
        procedure check(constant got, exp : std_logic_vector(127 downto 0);
                        constant label_s : string) is
        begin
            if got /= exp then
                r_errors <= r_errors + 1;
                report "FAIL: " & label_s & " mismatch (S_IDLE re-key race hit)"
                    severity error;
            else
                report "ok:   " & label_s & " matches reference" severity note;
            end if;
        end procedure;
    begin
        rstn <= '0';
        for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        for i in 1 to 2 loop wait until rising_edge(clk); end loop;

        -- Packet 1 setup: key 1 then IV 1 (single-cycle pulses)
        i_key <= c_KEY1; i_key_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';
        wait until rising_edge(clk);
        i_nonce <= c_IV1; i_nonce_valid <= '1';
        wait until rising_edge(clk);
        i_nonce_valid <= '0';

        -- H and EK of packet 1 (also proves the harness itself is sound)
        wait until rising_edge(clk) and o_H_valid = '1';
        check(o_H, c_H1, "H(K1)");
        wait until rising_edge(clk) and o_E_k_valid = '1';
        check(o_E_k, c_EK1, "EK(K1,IV1)");

        -- Stage the next packet's IV mid-run (goes to the shadow register,
        -- so r_have_nonce is already '1' when the flush applies it)
        wait until rising_edge(clk);
        i_nonce <= c_IV2; i_nonce_valid <= '1';
        wait until rising_edge(clk);
        i_nonce_valid <= '0';

        -- Two-beat packet 1 payload; the second beat carries tlast. The cycle
        -- its handshake completes is the flush cycle f.
        s_axis_tdata <= x"00112233445566778899aabbccddeeff";
        s_axis_tvalid <= '1'; s_axis_tlast <= '0';
        loop
            wait until rising_edge(clk);
            exit when s_axis_tready = '1';
        end loop;
        s_axis_tdata <= x"ffeeddccbbaa99887766554433221100";
        s_axis_tlast <= '1';
        loop
            wait until rising_edge(clk);
            exit when s_axis_tready = '1';
        end loop;
        -- Edge f -> f+1 has just passed: drive the race. i_key_valid is high
        -- during f+1, the wrapper's single S_IDLE cycle between the packets.
        s_axis_tvalid <= '0'; s_axis_tlast <= '0';
        i_key <= c_KEY2; i_key_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';

        -- Packet 2 side-band: with the race armed, a buggy wrapper captures
        -- the half-reloaded-keys block as H and the true H as EK.
        wait until rising_edge(clk) and o_H_valid = '1';
        check(o_H, c_H2, "H(K2)");
        wait until rising_edge(clk) and o_E_k_valid = '1';
        check(o_E_k, c_EK2, "EK(K2,IV2)");

        wait until rising_edge(clk);
        if r_errors = 0 then
            report "RESULT: PASS" severity note;
        else
            report "RESULT: FAIL (" & integer'image(r_errors) & " mismatches)"
                severity failure;
        end if;
        finish;
    end process;

    p_WATCHDOG : process
    begin
        wait for 200 us;
        report "tb: GLOBAL TIMEOUT" severity failure;
    end process;

end architecture;
