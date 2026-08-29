----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_ecdh_core_vec
-- Module Name   : tb_ecdh_core_vec - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : End-to-end test for ecdh_core_basic (Phase 1 merged core)
--                 Instantiates only ecdh_core_basic (ec_cswap + ec_step_mxy + gf_alu inside). From
--                 "<k> <x> <y> <b> <X1> <Z1> <X2> <Z2> <xa> <ya>" takes k,x,y,b as inputs and
--                 xa,ya as expected affine outputs; X1..Z2 skipped. Full ladder -> y-recovery
--                 (batch inversion) in one call. Golden: ec_ladder.py.
--                 ghdl -r --std=08 tb_ecdh_core_vec -gG_M=4   -gG_VEC_FILE=ladder_vec_gf4.txt
--                 ghdl -r --std=08 tb_ecdh_core_vec -gG_M=571 -gG_D=32 -gG_VEC_FILE=ladder_vec_b571.txt
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_ecdh_core_vec is
    generic (
        G_M        : integer := 4;
        G_D        : integer := 1;
        G_VEC_FILE : string  := "ladder_vec_gf4.txt"
    );
end entity;

architecture sim of tb_ecdh_core_vec is

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
    signal k, xb, yb, b   : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal ox, oy         : std_logic_vector(G_M-1 downto 0);
    signal busy, done     : std_logic;

begin

    clk <= not clk after 5 ns when not done_s else '0';

    u_dut : entity work.ecdh_core_basic
        generic map (G_M => G_M, G_D => G_D, G_F => f_poly(G_M))
        port map (
            i_clk => clk, i_resetn => rstn, i_start => start,
            i_k => k, i_xb => xb, i_yb => yb, i_b => b,
            o_x => ox, o_y => oy,
            o_busy => busy, o_done => done
        );

    p_main : process
        file     f_vec : text;
        variable l     : line;
        variable c     : character;
        variable ok    : boolean;
        variable vk, vx, vy, vb     : std_logic_vector(G_M-1 downto 0);
        variable vskip              : std_logic_vector(G_M-1 downto 0);
        variable exa, eya           : std_logic_vector(G_M-1 downto 0);
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
            read_bits(l, vy);    read(l, c, ok);
            read_bits(l, vb);    read(l, c, ok);
            read_bits(l, vskip); read(l, c, ok);   -- X1
            read_bits(l, vskip); read(l, c, ok);   -- Z1
            read_bits(l, vskip); read(l, c, ok);   -- X2
            read_bits(l, vskip); read(l, c, ok);   -- Z2
            read_bits(l, exa);   read(l, c, ok);
            read_bits(l, eya);

            k <= vk;  xb <= vx;  yb <= vy;  b <= vb;
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';

            g := 0;
            loop
                wait until rising_edge(clk);
                exit when done = '1';
                g := g + 1;
                assert g < 20*G_M*G_M + 200*G_M + 30000 report "TIMEOUT on vector "
                    & integer'image(n) severity failure;
            end loop;

            n := n + 1;
            if ox /= exa or oy /= eya then
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
