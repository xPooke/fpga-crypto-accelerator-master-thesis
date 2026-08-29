----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_sha3_dense
-- Module Name   : tb_sha3_dense - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Dense back-to-back traffic + output backpressure stress
--                 Independent driver and checker processes around sha3_axis_ip (SHA3-256):
--                 * driver pumps messages of length 1..G_MAX_LEN with TVALID held high
--                 continuously and ZERO idle cycles between packets - the first beat of
--                 message N+1 is already waiting while message N is being padded,
--                 permuted and squeezed;
--                 * checker collects each digest and compares against the hashlib vectors
--                 in len_sweep_sha3_256.txt; TLAST must come exactly on the final word;
--                 * with G_STALL = 1 an LFSR throttles m_axis_tready (~50% duty) so the
--                 output buffer must hold every word, including the last one, until the
--                 downstream accepts it.
--                 This targets the two flow-control hazards deferred from the style pass:
--                 input-buffer beat arriving during the padding cycle, and output-buffer
--                 last-word backpressure.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_sha3_dense is
    generic (
        G_ALGORITHM        : string  := "SHA3";   -- "SHA3" (SHA3-256) or "SHAKE"
        G_SHAKE_VERSION    : string  := "256";
        G_OUT_BITS         : integer := 256;      -- must match the vector file
        G_DATA_WIDTH       : integer := 32;
        G_ROUNDS_PER_CYCLE : integer := 1;
        G_STALL            : integer := 1;   -- 0 = always ready, 1 = LFSR throttle
        G_MAX_LEN          : integer := 160;
        G_VECTOR_FILE      : string  := "len_sweep_sha3_256.txt"
    );
end entity;

architecture sim of tb_sha3_dense is

    constant c_CLK_PERIOD : time    := 10 ns;
    constant c_WB         : integer := G_DATA_WIDTH / 8;
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
    signal m_tready : std_logic;
    signal m_tdata  : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
    signal m_tkeep  : std_logic_vector(c_WB - 1 downto 0);
    signal m_tlast  : std_logic;

    signal r_lfsr : std_logic_vector(7 downto 0) := x"5A";

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

    ----------------------------------------------------------------------------
    -- Downstream ready: all-ones or LFSR throttle (~50% duty, deterministic)
    ----------------------------------------------------------------------------
    p_STALL : process(clk)
    begin
        if rising_edge(clk) then
            r_lfsr <= r_lfsr(6 downto 0) &
                      (r_lfsr(7) xor r_lfsr(5) xor r_lfsr(4) xor r_lfsr(3));
        end if;
    end process;

    m_tready <= '1' when G_STALL = 0 else r_lfsr(0);

    ----------------------------------------------------------------------------
    -- Driver: messages back-to-back, TVALID never drops between packets
    ----------------------------------------------------------------------------
    p_DRIVER : process
        variable v_nbeats : integer;
        variable v_idx    : integer;
        variable v_guard  : integer;
    begin
        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;

        for len in 1 to G_MAX_LEN loop
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
                    assert v_guard < 50000
                        report "DRIVER TIMEOUT on s_axis_tready (len " & integer'image(len) & ")"
                        severity failure;
                end loop;
                -- no gap: the next beat (or next message) is driven immediately
            end loop;
        end loop;

        s_tvalid <= '0';
        s_tlast  <= '0';
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Checker: collects every digest, compares, verifies TLAST placement
    ----------------------------------------------------------------------------
    p_CHECKER : process
        file     f_vec     : text;
        variable v_line    : line;
        variable v_char    : character;
        variable v_good    : boolean;
        variable v_exp     : std_logic_vector(c_DIGEST - 1 downto 0);
        variable v_got     : std_logic_vector(c_DIGEST - 1 downto 0);
        variable v_idx     : integer;
        variable v_word    : integer;
        variable v_guard   : integer;
        variable v_errors  : integer := 0;
        variable v_faillog : line;
    begin
        file_open(f_vec, G_VECTOR_FILE, read_mode);
        wait until rstn = '1';

        for len in 1 to G_MAX_LEN loop
            readline(f_vec, v_line);
            for k in 0 to c_DIGEST / 4 - 1 loop
                read(v_line, v_char, v_good);
                assert v_good report "vector file: short line at len " & integer'image(len)
                    severity failure;
                v_exp(c_DIGEST - 1 - 4 * k downto c_DIGEST - 4 - 4 * k) := hex_to_slv4(v_char);
            end loop;

            v_word  := 0;
            v_guard := 0;
            while v_word < c_OUT_WORDS loop
                wait until rising_edge(clk);
                if m_tvalid = '1' and m_tready = '1' then
                    for j in 0 to c_WB - 1 loop
                        v_idx := v_word * c_WB + j;
                        v_got(c_DIGEST - 1 - 8 * v_idx downto c_DIGEST - 8 - 8 * v_idx)
                            := m_tdata(8 * j + 7 downto 8 * j);
                    end loop;
                    -- TLAST exactly on the final digest word
                    if (v_word = c_OUT_WORDS - 1) /= (m_tlast = '1') then
                        v_errors := v_errors + 1;
                        report "len " & integer'image(len) & ": TLAST misplaced on word "
                             & integer'image(v_word) severity error;
                    end if;
                    v_word := v_word + 1;
                end if;
                v_guard := v_guard + 1;
                assert v_guard < 100000
                    report "CHECKER TIMEOUT waiting for digest (len " & integer'image(len) & ")"
                    severity failure;
            end loop;

            if v_got /= v_exp then
                v_errors := v_errors + 1;
                write(v_faillog, integer'image(len) & " ");
                report "len " & integer'image(len) & ": digest FAIL" severity error;
            end if;
        end loop;

        file_close(f_vec);

        if v_errors = 0 then
            report "DENSE RESULT: ALL " & integer'image(G_MAX_LEN) & " PASS"
                 & " (DW=" & integer'image(G_DATA_WIDTH)
                 & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE)
                 & " STALL=" & integer'image(G_STALL) & ")";
        else
            report "DENSE RESULT: " & integer'image(v_errors) & " errors; digest fails at: "
                 & v_faillog.all severity error;
        end if;

        done <= true;
        wait;
    end process;

end architecture;
