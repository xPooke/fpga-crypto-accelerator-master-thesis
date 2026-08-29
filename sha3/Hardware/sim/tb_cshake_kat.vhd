----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_cshake_kat
-- Module Name   : tb_cshake_kat - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Known-answer test for the CSHAKE configuration (incl. KMAC)
--                 Vector file (gen_cshake_vectors.py): two lines per case -- line 1 is the
--                 COMPLETE message in hex exactly as it goes over AXIS (N/S prefix block,
--                 key block and right_encode(L) for KMAC are already part of it; that
--                 formatting is software's job), line 2 is the expected output (G_OUT_BITS).
--                 The reference model is validated against hashlib before emitting vectors.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_cshake_kat is
    generic (
        G_SHAKE_VERSION    : string  := "256";
        G_OUT_BITS         : integer := 512;
        G_DATA_WIDTH       : integer := 32;
        G_ROUNDS_PER_CYCLE : integer := 1;
        G_NUM_CASES        : integer := 4;
        G_VECTOR_FILE      : string  := "cshake256_kat_512.txt"
    );
end entity;

architecture sim of tb_cshake_kat is

    constant c_CLK_PERIOD : time    := 10 ns;
    constant c_WB         : integer := G_DATA_WIDTH / 8;
    constant c_OUT_WORDS  : integer := G_OUT_BITS / G_DATA_WIDTH;
    constant c_MSG_MAX    : integer := 2048;  -- max message bytes per case

    type byte_arr_t is array (0 to c_MSG_MAX - 1) of std_logic_vector(7 downto 0);

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
            ALGORITHM        => "CSHAKE",
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
        variable v_c1     : character;
        variable v_c2     : character;
        variable v_good   : boolean;
        variable v_msg    : byte_arr_t;
        variable v_len    : integer;
        variable v_exp    : std_logic_vector(G_OUT_BITS - 1 downto 0);
        variable v_got    : std_logic_vector(G_OUT_BITS - 1 downto 0);
        variable v_nbeats : integer;
        variable v_idx    : integer;
        variable v_word   : integer;
        variable v_guard  : integer;
        variable v_errors : integer := 0;
    begin
        report "cSHAKE KAT start: cSHAKE" & G_SHAKE_VERSION
             & " OUT=" & integer'image(G_OUT_BITS)
             & " DW=" & integer'image(G_DATA_WIDTH)
             & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE);

        file_open(f_vec, G_VECTOR_FILE, read_mode);

        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;

        for tc in 1 to G_NUM_CASES loop
            -- Line 1: the full DUT message (hex pairs until end of line)
            readline(f_vec, v_line);
            v_len := 0;
            loop
                read(v_line, v_c1, v_good);
                exit when not v_good;
                read(v_line, v_c2, v_good);
                assert v_good report "odd hex digit count in message line"
                    severity failure;
                v_msg(v_len) := hex_to_slv4(v_c1) & hex_to_slv4(v_c2);
                v_len := v_len + 1;
            end loop;

            -- Line 2: expected output
            readline(f_vec, v_line);
            for k in 0 to G_OUT_BITS / 4 - 1 loop
                read(v_line, v_c1, v_good);
                assert v_good report "short expected line" severity failure;
                v_exp(G_OUT_BITS - 1 - 4 * k downto G_OUT_BITS - 4 - 4 * k) := hex_to_slv4(v_c1);
            end loop;

            -- Send the message
            v_nbeats := (v_len + c_WB - 1) / c_WB;
            for b in 0 to v_nbeats - 1 loop
                for j in 0 to c_WB - 1 loop
                    v_idx := b * c_WB + j;
                    if v_idx < v_len then
                        s_tdata(8 * j + 7 downto 8 * j) <= v_msg(v_idx);
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
                        report "TIMEOUT on s_axis_tready (case " & integer'image(tc) & ")"
                        severity failure;
                end loop;
            end loop;
            s_tvalid <= '0';
            s_tlast  <= '0';
            s_tkeep  <= (others => '0');

            -- Collect the output
            v_word  := 0;
            v_guard := 0;
            while v_word < c_OUT_WORDS loop
                wait until rising_edge(clk);
                if m_tvalid = '1' then
                    for j in 0 to c_WB - 1 loop
                        v_idx := v_word * c_WB + j;
                        v_got(G_OUT_BITS - 1 - 8 * v_idx downto G_OUT_BITS - 8 - 8 * v_idx)
                            := m_tdata(8 * j + 7 downto 8 * j);
                    end loop;
                    v_word := v_word + 1;
                end if;
                v_guard := v_guard + 1;
                assert v_guard < 50000
                    report "TIMEOUT waiting for output (case " & integer'image(tc) & ")"
                    severity failure;
            end loop;

            if v_got = v_exp then
                report "case " & integer'image(tc) & " (msg " & integer'image(v_len)
                     & " B): PASS";
            else
                v_errors := v_errors + 1;
                report "case " & integer'image(tc) & " (msg " & integer'image(v_len)
                     & " B): FAIL" severity error;
            end if;

            for i in 0 to 9 loop wait until rising_edge(clk); end loop;
        end loop;

        file_close(f_vec);

        if v_errors = 0 then
            report "cSHAKE KAT RESULT: ALL " & integer'image(G_NUM_CASES)
                 & " PASS (cSHAKE" & G_SHAKE_VERSION
                 & " OUT=" & integer'image(G_OUT_BITS)
                 & " DW=" & integer'image(G_DATA_WIDTH)
                 & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE) & ")";
        else
            report "cSHAKE KAT RESULT: " & integer'image(v_errors) & " FAIL" severity failure;
        end if;

        done <= true;
        wait;
    end process;

end architecture;
