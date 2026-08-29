----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_ec_cswap
-- Module Name   : tb_ec_cswap - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Self-checking test for ec_cswap (combinational conditional swap)
--                 Reference is trivial (swap=1 -> crossed, swap=0 -> direct), so the expected
--                 value is computed in the TB, no vector file. GF(2^4): exhaustive over all
--                 x1,z1,x2,z2 and both swap bits; large m: patterns (counter/shift/invert).
--                 IMPORTANT: loops change DATA while swap is stable — catches a sensitivity
--                 list bug (process waking only on i_swap).
--                 ghdl -r --std=08 tb_ec_cswap                (G_M=4, exhaustive)
--                 ghdl -r --std=08 tb_ec_cswap -gG_M=571      (patterns)
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ec_cswap is
    generic (
        G_M : integer := 4
    );
end entity;

architecture sim of tb_ec_cswap is

    signal w_swap                   : std_logic := '0';
    signal w_x1, w_z1, w_x2, w_z2   : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal w_ox1, w_oz1, w_ox2, w_oz2 : std_logic_vector(G_M-1 downto 0);

begin

    u_dut : entity work.ec_cswap
        generic map (G_M => G_M)
        port map (i_swap => w_swap,
                  i_x1 => w_x1, i_z1 => w_z1, i_x2 => w_x2, i_z2 => w_z2,
                  o_x1 => w_ox1, o_z1 => w_oz1, o_x2 => w_ox2, o_z2 => w_oz2);

    p_STIM : process
        variable v_n        : integer := 0;
        variable v_ex1, v_ez1, v_ex2, v_ez2 : std_logic_vector(G_M-1 downto 0);

        procedure check is
        begin
            wait for 1 ns;
            if w_swap = '1' then
                v_ex1 := w_x2;  v_ez1 := w_z2;
                v_ex2 := w_x1;  v_ez2 := w_z1;
            else
                v_ex1 := w_x1;  v_ez1 := w_z1;
                v_ex2 := w_x2;  v_ez2 := w_z2;
            end if;
            assert w_ox1 = v_ex1 and w_oz1 = v_ez1 and
                   w_ox2 = v_ex2 and w_oz2 = v_ez2
                report "FAIL #" & integer'image(v_n) &
                       " swap=" & std_logic'image(w_swap)
                severity failure;
            v_n := v_n + 1;
        end procedure;

    begin
        if G_M = 4 then
            -- exhaustive: all inputs, swap in the OUTER loop (data changes while swap is stable)
            for s in 0 to 1 loop
                w_swap <= '0' when s = 0 else '1';
                for a in 0 to 15 loop
                    for b in 0 to 15 loop
                        for c in 0 to 15 loop
                            for d in 0 to 15 loop
                                w_x1 <= std_logic_vector(to_unsigned(a, G_M));
                                w_z1 <= std_logic_vector(to_unsigned(b, G_M));
                                w_x2 <= std_logic_vector(to_unsigned(c, G_M));
                                w_z2 <= std_logic_vector(to_unsigned(d, G_M));
                                check;
                            end loop;
                        end loop;
                    end loop;
                end loop;
            end loop;
        else
            -- patterns for large m: walking one, counter, invert, alternating
            for s in 0 to 1 loop
                w_swap <= '0' when s = 0 else '1';
                for i in 0 to G_M-1 loop
                    w_x1 <= (others => '0');  w_x1(i) <= '1';
                    w_z1 <= (others => '1');  w_z1(i) <= '0';
                    w_x2 <= std_logic_vector(to_unsigned(i, G_M));
                    w_z2 <= not std_logic_vector(to_unsigned(i, G_M));
                    check;
                end loop;
            end loop;
        end if;

        report "==== ALL " & integer'image(v_n) & " PASS (m=" &
               integer'image(G_M) & ") ====" severity note;
        wait;
    end process;

end architecture;
