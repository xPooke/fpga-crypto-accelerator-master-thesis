----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_ec_scalar_mult_par_vec
-- Module Name   : tb_ec_scalar_mult_par_vec - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : tb_ec_scalar_mult_par — file-based test for ec_scalar_mult_par (Phase 2)
--                 Self-contained (the DUT owns its multipliers; no external gf_alu). Reads
--                 "<k> <x> <y> <b> <X1> <Z1> <X2> <Z2> <xa> <ya>" (G_M-wide bit strings) from
--                 G_VEC_FILE; y, xa, ya are skipped (for ec_mxy). Drives k/x/b, compares the
--                 four projective outputs X1 Z1 X2 Z2. Golden: scalar_mult_ct in ec_ladder.py.
--                 ghdl -r --std=08 tb_ec_scalar_mult_par_vec -gG_M=4   -gG_VEC_FILE=ladder_vec_gf4.txt
--                 ghdl -r --std=08 tb_ec_scalar_mult_par_vec -gG_M=571 -gG_D=8 -gG_VEC_FILE=ladder_vec_b571.txt
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_ec_scalar_mult_par_vec is
    generic (
        G_M        : integer := 4;
        G_D        : integer := 1;
        G_VEC_FILE : string  := "ladder_vec_gf4.txt"
    );
end entity;

architecture sim of tb_ec_scalar_mult_par_vec is

    function f_poly(m : integer) return std_logic_vector is
        variable v : std_logic_vector(m downto 0) := (others => '0');
    begin
        v(m) := '1';
        if m = 4 then
            v(1) := '1'; v(0) := '1';
        elsif m = 571 then
            v(10) := '1'; v(5) := '1'; v(2) := '1'; v(0) := '1';
        else
            report "f_poly: unknown field m=" & integer'image(m) severity failure;
        end if;
        return v;
    end function;

    signal clk    : std_logic := '0';
    signal rstn   : std_logic := '0';
    signal done_s : boolean   := false;

    signal start          : std_logic := '0';
    signal k, xb, b       : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal x1, z1, x2, z2 : std_logic_vector(G_M-1 downto 0);
    signal busy, done     : std_logic;

begin

    clk <= not clk after 5 ns when not done_s else '0';

    u_dut : entity work.ec_scalar_mult_par
        generic map (G_M => G_M, G_D => G_D, G_F => f_poly(G_M))
        port map (
            i_clk => clk, i_resetn => rstn, i_start => start,
            i_k => k, i_xb => xb, i_b => b,
            o_x1 => x1, o_z1 => z1, o_x2 => x2, o_z2 => z2,
            o_busy => busy, o_done => done
        );

    p_main : process
        file     f_vec : text;
        variable l     : line;
        variable c     : character;
        variable ok    : boolean;
        variable vk, vx, vb         : std_logic_vector(G_M-1 downto 0);
        variable vskip              : std_logic_vector(G_M-1 downto 0);
        variable ex1, ez1, ex2, ez2 : std_logic_vector(G_M-1 downto 0);
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
            read_bits(l, vk);    read(l, c, ok);
            read_bits(l, vx);    read(l, c, ok);
            read_bits(l, vskip); read(l, c, ok);   -- y (for Mxy, skip)
            read_bits(l, vb);    read(l, c, ok);
            read_bits(l, ex1);   read(l, c, ok);
            read_bits(l, ez1);   read(l, c, ok);
            read_bits(l, ex2);   read(l, c, ok);
            read_bits(l, ez2);
            -- xa, ya at end of line are not read

            k  <= vk;  xb <= vx;  b <= vb;
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';

            g := 0;
            loop
                wait until rising_edge(clk);
                exit when done = '1';
                g := g + 1;
                assert g < 20*G_M*G_M + 10000 report "TIMEOUT on vector "
                    & integer'image(n) severity failure;
            end loop;

            n := n + 1;
            if x1 /= ex1 or z1 /= ez1 or x2 /= ex2 or z2 /= ez2 then
                nfail := nfail + 1;
                if nfail <= 8 then
                    report "FAIL vector " & integer'image(n-1) severity error;
                end if;
            end if;

            wait until rising_edge(clk);
        end loop;
        file_close(f_vec);

        if nfail = 0 then
            report "==== ALL " & integer'image(n) & " PASS (m="
                 & integer'image(G_M) & ", D=" & integer'image(G_D) & ") ====";
        else
            report "==== " & integer'image(nfail) & "/" & integer'image(n)
                 & " FAIL (m=" & integer'image(G_M) & ") ====" severity failure;
        end if;

        done_s <= true;
        wait;
    end process;

end architecture;
