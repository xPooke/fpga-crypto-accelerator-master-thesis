----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_ec_step_mxy_vec
-- Module Name   : tb_ec_step_mxy_vec - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : File-based test for the merged ec_step_mxy + gf_alu
--                 One TB, both modes (G_MODE generic):
--                 G_MODE=0 (step): reads step_vec "<x1> <z1> <x2> <z2> <xb> <b> <nx1> <nz1>
--                 <nx2> <nz2>", drives i_mode=0, compares o_x1..o_z2.
--                 G_MODE=1 (mxy):  reads ladder_vec "<k> <x> <y> <b> <X1> <Z1> <X2> <Z2> <xa>
--                 <ya>" (k,b skipped), drives i_mode=1 with X1..Z2 + (xb,yb),
--                 compares o_x,o_y to xa,ya.
--                 Golden: madd/mdouble + Mxy in ec_ladder.py. mode-1 uses batch inversion but
--                 must give identical affine (x,y).
--                 ghdl -r --std=08 tb_ec_step_mxy_vec -gG_M=4 -gG_MODE=0 -gG_VEC_FILE=step_vec_gf4.txt
--                 ghdl -r --std=08 tb_ec_step_mxy_vec -gG_M=4 -gG_MODE=1 -gG_VEC_FILE=ladder_vec_gf4.txt
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.gf_alu_pkg.all;

entity tb_ec_step_mxy_vec is
    generic (
        G_M        : integer := 4;
        G_D        : integer := 1;
        G_MODE     : integer := 0;                 -- 0 = step, 1 = mxy
        G_VEC_FILE : string  := "step_vec_gf4.txt"
    );
end entity;

architecture sim of tb_ec_step_mxy_vec is

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

    signal start                  : std_logic := '0';
    signal mode                   : std_logic := '0';
    signal x1, z1, x2, z2, xb, yb, b : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal ox1, oz1, ox2, oz2     : std_logic_vector(G_M-1 downto 0);
    signal oxa, oya               : std_logic_vector(G_M-1 downto 0);
    signal busy, done             : std_logic;

    signal alu_start : std_logic;
    signal alu_op    : alu_op_t;
    signal alu_a     : std_logic_vector(G_M-1 downto 0);
    signal alu_b     : std_logic_vector(G_M-1 downto 0);
    signal alu_busy  : std_logic;
    signal alu_done  : std_logic;
    signal alu_res   : std_logic_vector(G_M-1 downto 0);

begin

    clk <= not clk after 5 ns when not done_s else '0';
    mode <= '1' when G_MODE = 1 else '0';

    u_dut : entity work.ec_step_mxy
        generic map (G_M => G_M)
        port map (
            i_clk => clk, i_resetn => rstn, i_start => start, i_mode => mode,
            i_x1 => x1, i_z1 => z1, i_x2 => x2, i_z2 => z2,
            i_xb => xb, i_yb => yb, i_b => b,
            o_x1 => ox1, o_z1 => oz1, o_x2 => ox2, o_z2 => oz2,
            o_x => oxa, o_y => oya,
            o_busy => busy, o_done => done,
            o_alu_start => alu_start, o_alu_op => alu_op,
            o_alu_a => alu_a, o_alu_b => alu_b,
            i_alu_busy => alu_busy, i_alu_done => alu_done, i_alu_res => alu_res
        );

    u_alu : entity work.gf_alu
        generic map (G_M => G_M, G_D => G_D, G_F => f_poly(G_M))
        port map (
            i_clk => clk, i_resetn => rstn,
            i_op => alu_op, i_start => alu_start, i_a => alu_a, i_b => alu_b,
            o_res => alu_res, o_busy => alu_busy, o_done => alu_done
        );

    p_main : process
        file     f_vec : text;
        variable l     : line;
        variable c     : character;
        variable ok    : boolean;
        variable vx1, vz1, vx2, vz2 : std_logic_vector(G_M-1 downto 0);
        variable vxb, vyb, vb       : std_logic_vector(G_M-1 downto 0);
        variable vskip              : std_logic_vector(G_M-1 downto 0);
        variable e1, e2, e3, e4     : std_logic_vector(G_M-1 downto 0);  -- expected
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

            if G_MODE = 0 then
                -- step_vec: x1 z1 x2 z2 xb b nx1 nz1 nx2 nz2
                read_bits(l, vx1);  read(l, c, ok);
                read_bits(l, vz1);  read(l, c, ok);
                read_bits(l, vx2);  read(l, c, ok);
                read_bits(l, vz2);  read(l, c, ok);
                read_bits(l, vxb);  read(l, c, ok);
                read_bits(l, vb);   read(l, c, ok);
                read_bits(l, e1);   read(l, c, ok);   -- nx1
                read_bits(l, e2);   read(l, c, ok);   -- nz1
                read_bits(l, e3);   read(l, c, ok);   -- nx2
                read_bits(l, e4);                     -- nz2
                vyb := (others => '0');
            else
                -- ladder_vec: k x y b X1 Z1 X2 Z2 xa ya
                read_bits(l, vskip); read(l, c, ok);  -- k
                read_bits(l, vxb);   read(l, c, ok);  -- x  -> xb
                read_bits(l, vyb);   read(l, c, ok);  -- y  -> yb
                read_bits(l, vskip); read(l, c, ok);  -- b
                read_bits(l, vx1);   read(l, c, ok);  -- X1
                read_bits(l, vz1);   read(l, c, ok);  -- Z1
                read_bits(l, vx2);   read(l, c, ok);  -- X2
                read_bits(l, vz2);   read(l, c, ok);  -- Z2
                read_bits(l, e1);    read(l, c, ok);  -- xa
                read_bits(l, e2);                     -- ya
                vb := (others => '0');
            end if;

            x1 <= vx1;  z1 <= vz1;  x2 <= vx2;  z2 <= vz2;
            xb <= vxb;  yb <= vyb;  b <= vb;
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';

            g := 0;
            loop
                wait until rising_edge(clk);
                exit when done = '1';
                g := g + 1;
                assert g < 200*G_M + 20000 report "TIMEOUT on vector "
                    & integer'image(n) severity failure;
            end loop;

            n := n + 1;
            if G_MODE = 0 then
                if ox1 /= e1 or oz1 /= e2 or ox2 /= e3 or oz2 /= e4 then
                    nfail := nfail + 1;
                    if nfail <= 8 then
                        report "FAIL step vector " & integer'image(n-1) severity error;
                    end if;
                end if;
            else
                if oxa /= e1 or oya /= e2 then
                    nfail := nfail + 1;
                    if nfail <= 8 then
                        report "FAIL mxy vector " & integer'image(n-1) severity error;
                    end if;
                end if;
            end if;

            wait until rising_edge(clk);
        end loop;
        file_close(f_vec);

        if nfail = 0 then
            report "==== ALL " & integer'image(n) & " PASS (m="
                 & integer'image(G_M) & ", mode=" & integer'image(G_MODE)
                 & ", D=" & integer'image(G_D) & ") ====";
        else
            report "==== " & integer'image(nfail) & "/" & integer'image(n)
                 & " FAIL (m=" & integer'image(G_M) & ", mode=" & integer'image(G_MODE)
                 & ") ====" severity failure;
        end if;

        done_s <= true;
        wait;
    end process;

end architecture;
