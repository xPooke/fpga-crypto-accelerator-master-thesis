----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_gf_alu_vec
-- Module Name   : tb_gf_alu_vec - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : File-based test for gf_alu (all 4 operations)
--                 Reads "<op> <a> <b> <exp>" vectors from G_VEC_FILE (op: 0=ADD 1=SQR 2=MUL
--                 3=INV; a,b,exp are G_M-wide bit strings). Runs each command through the ALU
--                 and compares o_res with exp. Vectors from gf2m.py (golden model) via
--                 gen_alu_vectors.py.
--                 ghdl -r --std=08 tb_gf_alu_vec -gG_M=4   -gG_VEC_FILE=alu_vec_gf4.txt
--                 ghdl -r --std=08 tb_gf_alu_vec -gG_M=571 -gG_VEC_FILE=alu_vec_b571.txt
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.gf_alu_pkg.all;

entity tb_gf_alu_vec is
    generic (
        G_M        : integer := 4;
        G_D        : integer := 1;
        G_VEC_FILE : string  := "alu_vec_gf4.txt"
    );
end entity;

architecture sim of tb_gf_alu_vec is

    function f_poly(m : integer) return std_logic_vector is
        variable v : std_logic_vector(m downto 0) := (others => '0');
    begin
        v(m) := '1';
        if m = 4 then
            v(1) := '1'; v(0) := '1';
        elsif m = 7 then
            v(1) := '1'; v(0) := '1';
        elsif m = 571 then
            v(10) := '1'; v(5) := '1'; v(2) := '1'; v(0) := '1';
        else
            report "f_poly: unknown field m=" & integer'image(m) severity failure;
        end if;
        return v;
    end function;

    function to_op(n : integer) return alu_op_t is
    begin
        case n is
            when 0      => return ALU_ADD;
            when 1      => return ALU_SQR;
            when 2      => return ALU_MUL;
            when others => return ALU_INV;
        end case;
    end function;

    signal clk    : std_logic := '0';
    signal rstn   : std_logic := '0';
    signal done_s : boolean   := false;

    signal op     : alu_op_t := ALU_ADD;
    signal start  : std_logic := '0';
    signal a, b   : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal res    : std_logic_vector(G_M-1 downto 0);
    signal busy   : std_logic;
    signal done   : std_logic;

begin

    clk <= not clk after 5 ns when not done_s else '0';

    dut : entity work.gf_alu
        generic map (G_M => G_M, G_D => G_D, G_F => f_poly(G_M))
        port map (
            i_clk => clk, i_resetn => rstn, i_op => op, i_start => start,
            i_a => a, i_b => b, o_res => res, o_busy => busy, o_done => done
        );

    p_main : process
        file     f_vec : text;
        variable l     : line;
        variable c     : character;
        variable ok    : boolean;
        variable vop   : integer;
        variable va    : std_logic_vector(G_M-1 downto 0);
        variable vb    : std_logic_vector(G_M-1 downto 0);
        variable vexp  : std_logic_vector(G_M-1 downto 0);
        variable g     : integer;
        variable n     : integer := 0;
        variable nfail : integer := 0;

        procedure read_bits(variable ln : inout line;
                            v  : out std_logic_vector) is
            variable ch : character;
            variable okc : boolean;
        begin
            for i in v'range loop
                read(ln, ch, okc);
                assert okc report "short line in vector file" severity failure;
                if ch = '1' then v(i) := '1'; else v(i) := '0'; end if;
            end loop;
        end procedure;
    begin
        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        wait until rising_edge(clk);

        file_open(f_vec, G_VEC_FILE, read_mode);
        while not endfile(f_vec) loop
            readline(f_vec, l);
            next when l'length = 0;
            read(l, c, ok);                          -- op (single digit)
            vop := character'pos(c) - character'pos('0');
            read(l, c, ok);                          -- space
            read_bits(l, va);
            read(l, c, ok);
            read_bits(l, vb);
            read(l, c, ok);
            read_bits(l, vexp);

            op    <= to_op(vop);
            a     <= va;
            b     <= vb;
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';

            g := 0;
            loop
                wait until rising_edge(clk);
                exit when done = '1';
                g := g + 1;
                assert g < 70*G_M + 500 report "TIMEOUT on vector "
                    & integer'image(n) severity failure;
            end loop;

            n := n + 1;
            if res /= vexp then
                nfail := nfail + 1;
                if nfail <= 8 then
                    report "FAIL vector " & integer'image(n-1)
                        & " (op=" & integer'image(vop) & ")" severity error;
                end if;
            end if;

            wait until rising_edge(clk);
        end loop;
        file_close(f_vec);

        if nfail = 0 then
            report "==== ALL " & integer'image(n) & " PASS (m="
                 & integer'image(G_M) & ") ====";
        else
            report "==== " & integer'image(nfail) & "/" & integer'image(n)
                 & " FAIL (m=" & integer'image(G_M) & ") ====" severity failure;
        end if;

        done_s <= true;
        wait;
    end process;

end architecture;
