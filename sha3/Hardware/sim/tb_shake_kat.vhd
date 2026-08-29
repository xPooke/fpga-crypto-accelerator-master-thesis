----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_shake_kat
-- Module Name   : tb_shake_kat - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Known-answer test for the SHAKE128/256 XOF configuration
--                 Four messages per run (same shapes as tb_sha3_kat: "abc", 200 x 0xA3,
--                 rate-exact, rate-1), expected outputs read from a hashlib-generated file
--                 (one G_OUT_BITS-long hex digest per line). Multi-chunk squeeze is
--                 exercised whenever G_OUT_BITS exceeds the rate (1344 b for SHAKE128,
--                 1088 b for SHAKE256).
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_shake_kat is
    generic (
        G_SHAKE_VERSION    : string  := "256";
        G_OUT_BITS         : integer := 1024;
        G_DATA_WIDTH       : integer := 32;
        G_ROUNDS_PER_CYCLE : integer := 1;
        G_VECTOR_FILE      : string  := "shake256_kat_1024.txt"
    );
end entity;

architecture sim of tb_shake_kat is

    constant c_CLK_PERIOD : time    := 10 ns;
    constant c_WB         : integer := G_DATA_WIDTH / 8;
    constant c_OUT_WORDS  : integer := G_OUT_BITS / G_DATA_WIDTH;

    -- SHAKE128 rate = 168 bytes, SHAKE256 rate = 136 bytes
    function rate_bytes_f return integer is
    begin
        if G_SHAKE_VERSION = "128" then return 168; else return 136; end if;
    end function;
    constant c_RATE_BYTES : integer := rate_bytes_f;

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';
    signal done : boolean   := false;

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

    function msg_len(msg_id : integer) return integer is
    begin
        case msg_id is
            when 1      => return 3;
            when 2      => return 200;
            when 3      => return c_RATE_BYTES;
            when others => return c_RATE_BYTES - 1;
        end case;
    end function;

    function msg_byte(msg_id : integer; idx : integer) return std_logic_vector is
    begin
        case msg_id is
            when 1 =>
                case idx is
                    when 0      => return x"61";
                    when 1      => return x"62";
                    when others => return x"63";
                end case;
            when 2      => return x"A3";
            when others => return std_logic_vector(to_unsigned(idx mod 256, 8));
        end case;
    end function;

    function hex_to_slv4(c : character) return std_logic_vector is
    begin
        case c is
            when '0' => return x"0"; when '1' => return x"1";
            when '2' => return x"2"; when '3' => return x"3";
            when '4' => return x"4"; when '5' => return x"5";
            when '6' => return x"6"; when '7' => return x"7";
            when '8' => return x"8"; when '9' => return x"9";
            when 'a' | 'A' => return x"A"; when 'b' | 'B' => return x"B";
            when 'c' | 'C' => return x"C"; when 'd' | 'D' => return x"D";
            when 'e' | 'E' => return x"E"; when others => return x"F";
        end case;
    end function;

begin

    clk <= not clk after c_CLK_PERIOD / 2 when not done else '0';

    u_dut : entity work.sha3_axis_ip
        generic map (
            ALGORITHM        => "SHAKE",
            SHAKE_VERSION    => G_SHAKE_VERSION,
            SHAKE_BITS       => G_OUT_BITS,
            DATA_WIDTH       => G_DATA_WIDTH,
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
        file     f_vec    : text;
        variable v_line   : line;
        variable v_char   : character;
        variable v_good   : boolean;
        variable v_exp    : std_logic_vector(G_OUT_BITS - 1 downto 0);
        variable v_got    : std_logic_vector(G_OUT_BITS - 1 downto 0);
        variable v_len    : integer;
        variable v_nbeats : integer;
        variable v_idx    : integer;
        variable v_word   : integer;
        variable v_guard  : integer;
        variable v_errors : integer := 0;
        variable v_last_ok : boolean;
    begin
        report "SHAKE KAT start: SHAKE" & G_SHAKE_VERSION
             & " OUT=" & integer'image(G_OUT_BITS)
             & " DW=" & integer'image(G_DATA_WIDTH)
             & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE);

        file_open(f_vec, G_VECTOR_FILE, read_mode);

        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;

        for msg in 1 to 4 loop
            -- Expected output: line "msg" of the vector file
            readline(f_vec, v_line);
            for k in 0 to G_OUT_BITS / 4 - 1 loop
                read(v_line, v_char, v_good);
                assert v_good report "vector file: short line at msg " & integer'image(msg)
                    severity failure;
                v_exp(G_OUT_BITS - 1 - 4 * k downto G_OUT_BITS - 4 - 4 * k) := hex_to_slv4(v_char);
            end loop;

            -- Send the message
            v_len    := msg_len(msg);
            v_nbeats := (v_len + c_WB - 1) / c_WB;
            for b in 0 to v_nbeats - 1 loop
                for j in 0 to c_WB - 1 loop
                    v_idx := b * c_WB + j;
                    if v_idx < v_len then
                        s_tdata(8 * j + 7 downto 8 * j) <= msg_byte(msg, v_idx);
                        s_tkeep(j) <= '1';
                    else
                        s_tdata(8 * j + 7 downto 8 * j) <= x"AA";
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
                    assert v_guard < 5000
                        report "TIMEOUT on s_axis_tready (msg " & integer'image(msg) & ")"
                        severity failure;
                end loop;
            end loop;
            s_tvalid <= '0';
            s_tlast  <= '0';
            s_tkeep  <= (others => '0');

            -- Collect the XOF output
            v_word    := 0;
            v_guard   := 0;
            v_last_ok := false;
            while v_word < c_OUT_WORDS loop
                wait until rising_edge(clk);
                if m_tvalid = '1' then
                    for j in 0 to c_WB - 1 loop
                        v_idx := v_word * c_WB + j;
                        v_got(G_OUT_BITS - 1 - 8 * v_idx downto G_OUT_BITS - 8 - 8 * v_idx)
                            := m_tdata(8 * j + 7 downto 8 * j);
                    end loop;
                    if v_word = c_OUT_WORDS - 1 and m_tlast = '1' then
                        v_last_ok := true;
                    end if;
                    v_word := v_word + 1;
                end if;
                v_guard := v_guard + 1;
                assert v_guard < 50000
                    report "TIMEOUT waiting for output (msg " & integer'image(msg) & ")"
                    severity failure;
            end loop;

            if v_got = v_exp then
                report "msg " & integer'image(msg) & " (len " & integer'image(v_len) & "): PASS";
            else
                v_errors := v_errors + 1;
                report "msg " & integer'image(msg) & " (len " & integer'image(v_len) & "): FAIL"
                    severity error;
            end if;
            if not v_last_ok then
                v_errors := v_errors + 1;
                report "msg " & integer'image(msg) & ": TLAST not on final output word"
                    severity error;
            end if;

            for i in 0 to 9 loop wait until rising_edge(clk); end loop;
        end loop;

        file_close(f_vec);

        if v_errors = 0 then
            report "SHAKE KAT RESULT: ALL 4 PASS (SHAKE" & G_SHAKE_VERSION
                 & " OUT=" & integer'image(G_OUT_BITS)
                 & " DW=" & integer'image(G_DATA_WIDTH)
                 & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE) & ")";
        else
            report "SHAKE KAT RESULT: " & integer'image(v_errors) & " FAIL" severity failure;
        end if;

        done <= true;
        wait;
    end process;

end architecture;
