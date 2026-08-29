----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_sha3_overlap
-- Module Name   : tb_sha3_overlap - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Proves the three pipeline overlaps with cycle counters
--                 Config: SHAKE256, DATA_WIDTH=32 (rate = 34 words), SHAKE_BITS=8192
--                 (8 squeeze chunks), RPC=1 (permutation = 24 cycles, the stress case).
--                 Two 1360-byte (10-block) messages driven back-to-back, m_axis_tready = '1'.
--                 C1 ABSORB OVERLAP: input beats are accepted WHILE the sponge permutes.
--                 Measured: input-acceptance span of one message. Parallel bound:
--                 ~10 blocks x ~36 cyc = ~370 (input never waits for a permutation);
--                 serial would be ~10 x (34 + 24 + 2) = ~600. Assert span < 450.
--                 C2 SQUEEZE OVERLAP: the sponge permutes chunk k+1 WHILE the output
--                 buffer drains chunk k. Measured: the 256-word output burst must be
--                 GAPLESS (24-cycle permutation hidden behind the 34-cycle drain, plus
--                 zero-bubble chunk splice). Assert: 256 valid beats in 256 cycles.
--                 C3 INPUT/OUTPUT OVERLAP: message 2 beats are accepted WHILE message 1
--                 output is still streaming. Assert: overlap counter > 0.
--                 Digests are also checked against hashlib, so the overlaps cannot be
--                 "achieved" by corrupting data.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_sha3_overlap is
    generic (
        G_VECTOR_FILE : string := "overlap_shake256_8192.txt"
    );
end entity;

architecture sim of tb_sha3_overlap is

    constant c_CLK_PERIOD : time    := 10 ns;
    constant c_DW         : integer := 32;
    constant c_WB         : integer := c_DW / 8;
    constant c_OUT_BITS   : integer := 8192;
    constant c_OUT_WORDS  : integer := c_OUT_BITS / c_DW;   -- 256
    constant c_MSG_BYTES  : integer := 1360;                 -- 10 rate blocks
    constant c_MSG_BEATS  : integer := c_MSG_BYTES / c_WB;   -- 340

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';
    signal done : boolean   := false;

    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tdata  : std_logic_vector(c_DW - 1 downto 0) := (others => '0');
    signal s_tkeep  : std_logic_vector(c_WB - 1 downto 0) := (others => '0');
    signal s_tlast  : std_logic := '0';

    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '1';
    signal m_tdata  : std_logic_vector(c_DW - 1 downto 0);
    signal m_tkeep  : std_logic_vector(c_WB - 1 downto 0);
    signal m_tlast  : std_logic;

    -- monitor counters (written by p_MONITOR, read by the checker at the end)
    signal r_in_first  : integer := -1;  -- cycle of the very first input handshake
    signal r_in_count  : integer := 0;   -- total input handshakes
    signal r_span1     : integer := -1;  -- input span of message 1 (set at its last beat)
    signal r_overlap   : integer := 0;   -- input handshakes while m_axis_tvalid = '1'
    signal r_cycle     : integer := 0;

    function msg_byte(msg_id : integer; idx : integer) return std_logic_vector is
    begin
        if msg_id = 1 then
            return std_logic_vector(to_unsigned(idx mod 256, 8));
        else
            return x"A3";
        end if;
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
            SHAKE_VERSION    => "256",
            SHAKE_BITS       => c_OUT_BITS,
            DATA_WIDTH       => c_DW,
            ROUNDS_PER_CYCLE => 1
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
    -- Cycle counter + overlap monitor
    ----------------------------------------------------------------------------
    p_MONITOR : process(clk)
    begin
        if rising_edge(clk) then
            r_cycle <= r_cycle + 1;
            if s_tvalid = '1' and s_tready = '1' then
                if r_in_first < 0 then
                    r_in_first <= r_cycle;
                end if;
                r_in_count <= r_in_count + 1;
                -- this handshake completes message 1: record its span
                if r_in_count = c_MSG_BEATS - 1 then
                    r_span1 <= r_cycle - r_in_first;
                end if;
                if m_tvalid = '1' then
                    r_overlap <= r_overlap + 1;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Driver: both messages back-to-back, independent of the checker, so
    -- message 2 is driven WHILE message 1 output streams (that is C3)
    ----------------------------------------------------------------------------
    p_DRIVER : process
        variable v_guard : integer;
    begin
        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;

        for msg in 1 to 2 loop
            for b in 0 to c_MSG_BEATS - 1 loop
                for j in 0 to c_WB - 1 loop
                    s_tdata(8 * j + 7 downto 8 * j) <= msg_byte(msg, b * c_WB + j);
                    s_tkeep(j) <= '1';
                end loop;
                s_tvalid <= '1';
                if b = c_MSG_BEATS - 1 then s_tlast <= '1'; else s_tlast <= '0'; end if;
                v_guard := 0;
                loop
                    wait until rising_edge(clk);
                    exit when s_tready = '1';
                    v_guard := v_guard + 1;
                    assert v_guard < 50000 report "input TIMEOUT" severity failure;
                end loop;
            end loop;
        end loop;
        s_tvalid <= '0';
        s_tlast  <= '0';
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Checker
    ----------------------------------------------------------------------------
    p_MAIN : process
        file     f_vec     : text;
        variable v_line    : line;
        variable v_char    : character;
        variable v_good    : boolean;
        variable v_exp     : std_logic_vector(c_OUT_BITS - 1 downto 0);
        variable v_got     : std_logic_vector(c_OUT_BITS - 1 downto 0);
        variable v_idx     : integer;
        variable v_word    : integer;
        variable v_guard   : integer;
        variable v_errors  : integer := 0;
        variable v_span    : integer;
        variable v_out_first : integer;
        variable v_out_beats : integer;
    begin
        file_open(f_vec, G_VECTOR_FILE, read_mode);
        wait until rstn = '1';

        for msg in 1 to 2 loop
            readline(f_vec, v_line);
            for k in 0 to c_OUT_BITS / 4 - 1 loop
                read(v_line, v_char, v_good);
                assert v_good report "vector file: short line" severity failure;
                v_exp(c_OUT_BITS - 1 - 4 * k downto c_OUT_BITS - 4 - 4 * k) := hex_to_slv4(v_char);
            end loop;

            -- ---- collect the 256-word output burst --------------------------
            v_word      := 0;
            v_guard     := 0;
            v_out_first := -1;
            v_out_beats := 0;
            while v_word < c_OUT_WORDS loop
                wait until rising_edge(clk);
                if m_tvalid = '1' then
                    if v_out_first < 0 then v_out_first := r_cycle; end if;
                    v_out_beats := v_out_beats + 1;
                    for j in 0 to c_WB - 1 loop
                        v_idx := v_word * c_WB + j;
                        v_got(c_OUT_BITS - 1 - 8 * v_idx downto c_OUT_BITS - 8 - 8 * v_idx)
                            := m_tdata(8 * j + 7 downto 8 * j);
                    end loop;
                    v_word := v_word + 1;
                end if;
                v_guard := v_guard + 1;
                assert v_guard < 50000 report "output TIMEOUT" severity failure;
            end loop;

            -- C2: squeeze overlap -- the burst must be gapless: 256 beats in
            -- exactly 256 cycles (permutations fully hidden + zero-bubble splice)
            v_span := r_cycle - v_out_first;
            report "C2 msg " & integer'image(msg) & ": output burst = "
                 & integer'image(v_out_beats) & " beats in "
                 & integer'image(v_span) & " cycles (serial would be ~"
                 & integer'image(c_OUT_WORDS + 7 * 24) & "+)";
            if v_span > c_OUT_WORDS then
                v_errors := v_errors + 1;
                report "C2 FAIL: gaps inside the output burst (squeeze not overlapped)"
                    severity error;
            end if;

            -- functional check
            if v_got /= v_exp then
                v_errors := v_errors + 1;
                report "DIGEST FAIL msg " & integer'image(msg) severity error;
            end if;
        end loop;

        file_close(f_vec);

        -- C1: absorb overlap -- input span of message 1 (recorded by the
        -- monitor; message 2 legitimately stalls behind msg 1's squeeze)
        report "C1: input span = " & integer'image(r_span1) & " cycles for "
             & integer'image(c_MSG_BEATS) & " beats (serial would be ~600)";
        if r_span1 < 0 or r_span1 >= 450 then
            v_errors := v_errors + 1;
            report "C1 FAIL: input stalled on permutations (no absorb overlap)"
                severity error;
        end if;

        -- C3: input/output overlap -- message 2 was partially absorbed while
        -- message 1 output was still on the bus
        report "C3: input handshakes during active output = " & integer'image(r_overlap);
        if r_overlap = 0 then
            v_errors := v_errors + 1;
            report "C3 FAIL: no input/output overlap observed" severity error;
        end if;

        if v_errors = 0 then
            report "OVERLAP RESULT: ALL 3 OVERLAPS CONFIRMED + digests match";
        else
            report "OVERLAP RESULT: " & integer'image(v_errors) & " FAIL" severity failure;
        end if;

        done <= true;
        wait;
    end process;

end architecture;
