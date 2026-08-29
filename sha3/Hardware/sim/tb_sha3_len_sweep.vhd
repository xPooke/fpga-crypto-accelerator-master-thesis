----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_sha3_len_sweep
-- Module Name   : tb_sha3_len_sweep - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Every message length 1..160 vs hashlib (SHA3-256)
--                 Reads len_sweep_sha3_256.txt (line L = sha3_256 digest of the incrementing
--                 byte pattern 0,1,2,... of length L) and hashes each length through
--                 sha3_axis_ip. The point is to map padding-path coverage exhaustively:
--                 every (length mod rate) residue, every TKEEP pattern, block-boundary and
--                 rate-1 corner cases included. SHA3-256 rate = 136 bytes, so 1..160 covers
--                 a full rate block plus the wrap into a second block.
--                 Reports a PASS/FAIL line per length and a final summary listing the
--                 failing lengths (none expected after the Input_buffer padding fix).
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_sha3_len_sweep is
    generic (
        G_ALGORITHM        : string  := "SHA3";   -- "SHA3" (SHA3-256) or "SHAKE"
        G_SHAKE_VERSION    : string  := "256";
        G_OUT_BITS         : integer := 256;      -- must match the vector file
        G_DATA_WIDTH       : integer := 32;
        G_ROUNDS_PER_CYCLE : integer := 1;
        G_MAX_LEN          : integer := 160;
        G_VECTOR_FILE      : string  := "len_sweep_sha3_256.txt"
    );
end entity;

architecture sim of tb_sha3_len_sweep is

    constant c_CLK_PERIOD : time    := 10 ns;
    constant c_WB         : integer := G_DATA_WIDTH / 8;   -- bytes per beat
    constant c_DIGEST     : integer := G_OUT_BITS;
    constant c_OUT_WORDS  : integer := c_DIGEST / G_DATA_WIDTH;

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

    -- One hex char -> 4 bits
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
            ALGORITHM        => G_ALGORITHM,
            SHA3_VERSION     => "256",
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
        file     f_vec     : text;
        variable v_line    : line;
        variable v_char    : character;
        variable v_good    : boolean;
        variable v_exp     : std_logic_vector(c_DIGEST - 1 downto 0);
        variable v_got     : std_logic_vector(c_DIGEST - 1 downto 0);
        variable v_nbeats  : integer;
        variable v_idx     : integer;
        variable v_word    : integer;
        variable v_guard   : integer;
        variable v_errors  : integer := 0;
        variable v_faillog : line;
    begin
        file_open(f_vec, G_VECTOR_FILE, read_mode);

        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;

        for len in 1 to G_MAX_LEN loop
            -- Expected digest: line "len" of the vector file
            readline(f_vec, v_line);
            for k in 0 to c_DIGEST / 4 - 1 loop
                read(v_line, v_char, v_good);
                assert v_good report "vector file: short line at len " & integer'image(len)
                    severity failure;
                v_exp(c_DIGEST - 1 - 4 * k downto c_DIGEST - 4 - 4 * k) := hex_to_slv4(v_char);
            end loop;

            -- Send message: incrementing byte pattern, 0xAA in TKEEP-masked bytes
            v_nbeats := (len + c_WB - 1) / c_WB;
            for b in 0 to v_nbeats - 1 loop
                for j in 0 to c_WB - 1 loop
                    v_idx := b * c_WB + j;
                    if v_idx < len then
                        s_tdata(8 * j + 7 downto 8 * j) <=
                            std_logic_vector(to_unsigned(v_idx mod 256, 8));
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
                    assert v_guard < 2000
                        report "TIMEOUT on s_axis_tready (len " & integer'image(len) & ")"
                        severity failure;
                end loop;
            end loop;
            s_tvalid <= '0';
            s_tlast  <= '0';
            s_tkeep  <= (others => '0');

            -- Collect digest
            v_word  := 0;
            v_guard := 0;
            while v_word < c_OUT_WORDS loop
                wait until rising_edge(clk);
                if m_tvalid = '1' then
                    for j in 0 to c_WB - 1 loop
                        v_idx := v_word * c_WB + j;
                        v_got(c_DIGEST - 1 - 8 * v_idx downto c_DIGEST - 8 - 8 * v_idx)
                            := m_tdata(8 * j + 7 downto 8 * j);
                    end loop;
                    v_word := v_word + 1;
                end if;
                v_guard := v_guard + 1;
                assert v_guard < 20000
                    report "TIMEOUT on digest (len " & integer'image(len) & ")"
                    severity failure;
            end loop;

            if v_got /= v_exp then
                v_errors := v_errors + 1;
                write(v_faillog, integer'image(len) & " ");
                report "len " & integer'image(len) & ": FAIL" severity error;
            end if;

            for i in 0 to 7 loop wait until rising_edge(clk); end loop;
        end loop;

        file_close(f_vec);

        if v_errors = 0 then
            report "LEN SWEEP RESULT: ALL " & integer'image(G_MAX_LEN) & " PASS"
                 & " (DW=" & integer'image(G_DATA_WIDTH)
                 & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE) & ")";
        else
            report "LEN SWEEP RESULT: " & integer'image(v_errors) & " FAIL at lengths: "
                 & v_faillog.all severity error;
        end if;

        done <= true;
        wait;
    end process;

end architecture;
