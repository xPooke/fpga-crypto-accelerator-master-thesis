----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_sha3_kat
-- Module Name   : tb_sha3_kat - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Known-answer test for sha3_axis_ip against NIST vectors
--                 Drives the AXI-Stream wrapper with the four messages defined in
--                 tb_sha3_vectors_pkg and compares each digest with the hashlib reference.
--                 One (G_VERSION, G_DATA_WIDTH, G_ROUNDS_PER_CYCLE) combo per run; the
--                 sweep script elaborates this TB once and re-runs it with -g overrides.
--                 Byte order convention checked here: message byte k rides in
--                 tdata(8*(k mod WB)+7 downto 8*(k mod WB)) of beat k/WB (AXIS byte 0 =
--                 tdata LSB byte), and the first digest byte out is the most significant
--                 hex pair of the textual digest. Bytes masked out by TKEEP are driven
--                 with 0xAA to prove the DUT really ignores them.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.tb_sha3_vectors_pkg.all;

entity tb_sha3_kat is
    generic (
        G_VERSION          : string  := "256";
        G_DATA_WIDTH       : integer := 32;
        G_ROUNDS_PER_CYCLE : integer := 1
    );
end entity;

architecture sim of tb_sha3_kat is

    constant c_CLK_PERIOD : time    := 10 ns;
    constant c_WB         : integer := G_DATA_WIDTH / 8;            -- bytes per beat
    constant c_DIGEST     : integer := digest_bits(G_VERSION);
    constant c_OUT_WORDS  : integer := c_DIGEST / G_DATA_WIDTH;

    signal clk    : std_logic := '0';
    signal rstn   : std_logic := '0';
    signal done   : boolean   := false;

    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tdata  : std_logic_vector(G_DATA_WIDTH - 1 downto 0) := (others => '0');
    signal s_tkeep  : std_logic_vector(c_WB - 1 downto 0) := (others => '0');
    signal s_tlast  : std_logic := '0';

    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '1';
    signal m_tdata  : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
    signal m_tkeep  : std_logic_vector(c_WB - 1 downto 0);
    signal m_tlast  : std_logic;

begin

    clk <= not clk after c_CLK_PERIOD / 2 when not done else '0';

    u_dut : entity work.sha3_axis_ip
        generic map (
            DATA_WIDTH       => G_DATA_WIDTH,
            SHA3_VERSION     => G_VERSION,
            ROUNDS_PER_CYCLE => G_ROUNDS_PER_CYCLE
        )
        port map (
            axis_aclk    => clk,
            axis_aresetn => rstn,
            s_axis_tvalid => s_tvalid,
            s_axis_tready => s_tready,
            s_axis_tdata  => s_tdata,
            s_axis_tkeep  => s_tkeep,
            s_axis_tlast  => s_tlast,
            m_axis_tvalid => m_tvalid,
            m_axis_tready => m_tready,
            m_axis_tdata  => m_tdata,
            m_axis_tkeep  => m_tkeep,
            m_axis_tlast  => m_tlast
        );

    p_MAIN : process
        variable v_len      : integer;
        variable v_nbeats   : integer;
        variable v_idx      : integer;
        variable v_got      : std_logic_vector(c_DIGEST - 1 downto 0);
        variable v_exp      : std_logic_vector(c_DIGEST - 1 downto 0);
        variable v_word     : integer;
        variable v_guard    : integer;
        variable v_errors   : integer := 0;
        variable v_last_ok  : boolean;
    begin
        report "KAT start: SHA3-" & G_VERSION
             & " DW=" & integer'image(G_DATA_WIDTH)
             & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE);

        -- Reset
        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;

        for msg in 1 to 4 loop
            v_len    := msg_len(msg, G_VERSION);
            v_nbeats := (v_len + c_WB - 1) / c_WB;

            -- Send the message
            for b in 0 to v_nbeats - 1 loop
                for j in 0 to c_WB - 1 loop
                    v_idx := b * c_WB + j;
                    if v_idx < v_len then
                        s_tdata(8 * j + 7 downto 8 * j) <= msg_byte(msg, v_idx);
                        s_tkeep(j) <= '1';
                    else
                        s_tdata(8 * j + 7 downto 8 * j) <= x"AA";  -- garbage, TKEEP-masked
                        s_tkeep(j) <= '0';
                    end if;
                end loop;
                s_tvalid <= '1';
                if b = v_nbeats - 1 then s_tlast <= '1'; else s_tlast <= '0'; end if;

                v_guard := 0;
                loop
                    wait until rising_edge(clk);
                    exit when s_tready = '1';
                    v_guard := v_guard + 1;
                    assert v_guard < 2000
                        report "TIMEOUT waiting for s_axis_tready (msg " & integer'image(msg) & ")"
                        severity failure;
                end loop;
            end loop;
            s_tvalid <= '0';
            s_tlast  <= '0';
            s_tkeep  <= (others => '0');

            -- Collect the digest (m_tready held high)
            v_word    := 0;
            v_guard   := 0;
            v_last_ok := false;
            while v_word < c_OUT_WORDS loop
                wait until rising_edge(clk);
                if m_tvalid = '1' then
                    for j in 0 to c_WB - 1 loop
                        v_idx := v_word * c_WB + j;  -- digest byte index, reading order
                        v_got(c_DIGEST - 1 - 8 * v_idx downto c_DIGEST - 8 - 8 * v_idx)
                            := m_tdata(8 * j + 7 downto 8 * j);
                    end loop;
                    if v_word = c_OUT_WORDS - 1 and m_tlast = '1' then
                        v_last_ok := true;
                    end if;
                    v_word := v_word + 1;
                end if;
                v_guard := v_guard + 1;
                assert v_guard < 20000
                    report "TIMEOUT waiting for digest (msg " & integer'image(msg) & ")"
                    severity failure;
            end loop;

            -- Compare
            v_exp := expected_digest(G_VERSION, msg);
            if v_got = v_exp then
                report "msg " & integer'image(msg) & " (len " & integer'image(v_len) & "): PASS";
            else
                v_errors := v_errors + 1;
                report "msg " & integer'image(msg) & " (len " & integer'image(v_len) & "): FAIL" & LF
                     & "  got      " & to_hstring(v_got) & LF
                     & "  expected " & to_hstring(v_exp)
                    severity error;
            end if;
            if not v_last_ok then
                report "msg " & integer'image(msg) & ": TLAST not aligned with final digest word"
                    severity warning;
            end if;

            -- Idle gap before the next message
            for i in 0 to 9 loop wait until rising_edge(clk); end loop;
        end loop;

        if v_errors = 0 then
            report "KAT RESULT: ALL 4 PASS (SHA3-" & G_VERSION
                 & " DW=" & integer'image(G_DATA_WIDTH)
                 & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE) & ")";
        else
            report "KAT RESULT: " & integer'image(v_errors) & " FAIL" severity failure;
        end if;

        done <= true;
        wait;
    end process;

end architecture;
