----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_ec_point_step_par_vec
-- Module Name   : tb_ec_point_step_par_vec - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : tb_ec_point_step_par — file-based test for ec_point_step_par (Phase 2)
--                 Same vectors and golden model as tb_ec_point_step_vec, but the DUT owns its
--                 three multipliers (no external gf_alu). Reads
--                 "<x1> <z1> <x2> <z2> <xb> <b> <nx1> <nz1> <nx2> <nz2>" (G_M-wide bit strings)
--                 from G_VEC_FILE, runs one step, compares all four outputs. b varies per
--                 vector (kept as a runtime input), so the existing random-b vectors apply.
--                 ghdl -r --std=08 tb_ec_point_step_par_vec -gG_M=4   -gG_VEC_FILE=step_vec_gf4.txt
--                 ghdl -r --std=08 tb_ec_point_step_par_vec -gG_M=571 -gG_D=8 -gG_VEC_FILE=step_vec_b571.txt
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_ec_point_step_par_vec is
    generic (
        G_M        : integer := 4;
        G_D        : integer := 1;
        G_VEC_FILE : string  := "step_vec_gf4.txt"
    );
end entity;

architecture sim of tb_ec_point_step_par_vec is

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
    signal x1, z1, x2, z2, xb, b  : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal ox1, oz1, ox2, oz2     : std_logic_vector(G_M-1 downto 0);
    signal busy, done             : std_logic;

begin

    clk <= not clk after 5 ns when not done_s else '0';

    u_dut : entity work.ec_point_step_par
        generic map (G_M => G_M, G_D => G_D, G_F => f_poly(G_M))
        port map (
            i_clk => clk, i_resetn => rstn, i_start => start,
            i_x1 => x1, i_z1 => z1, i_x2 => x2, i_z2 => z2,
            i_xb => xb, i_b => b,
            o_x1 => ox1, o_z1 => oz1, o_x2 => ox2, o_z2 => oz2,
            o_busy => busy, o_done => done
        );

    p_main : process
        file     f_vec : text;
        variable l     : line;
        variable c     : character;
        variable ok    : boolean;
        variable vx1, vz1, vx2, vz2 : std_logic_vector(G_M-1 downto 0);
        variable vxb, vb            : std_logic_vector(G_M-1 downto 0);
        variable enx1, enz1         : std_logic_vector(G_M-1 downto 0);
        variable enx2, enz2         : std_logic_vector(G_M-1 downto 0);
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
            read_bits(l, vx1);  read(l, c, ok);
            read_bits(l, vz1);  read(l, c, ok);
            read_bits(l, vx2);  read(l, c, ok);
            read_bits(l, vz2);  read(l, c, ok);
            read_bits(l, vxb);  read(l, c, ok);
            read_bits(l, vb);   read(l, c, ok);
            read_bits(l, enx1); read(l, c, ok);
            read_bits(l, enz1); read(l, c, ok);
            read_bits(l, enx2); read(l, c, ok);
            read_bits(l, enz2);

            x1 <= vx1;  z1 <= vz1;  x2 <= vx2;  z2 <= vz2;
            xb <= vxb;  b  <= vb;
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';

            -- 2 rounds of 3 muls (~ceil(m/D) each) + protocol overhead
            g := 0;
            loop
                wait until rising_edge(clk);
                exit when done = '1';
                g := g + 1;
                assert g < 40*G_M + 3000 report "TIMEOUT on vector "
                    & integer'image(n) severity failure;
            end loop;

            n := n + 1;
            if ox1 /= enx1 or oz1 /= enz1 or ox2 /= enx2 or oz2 /= enz2 then
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
