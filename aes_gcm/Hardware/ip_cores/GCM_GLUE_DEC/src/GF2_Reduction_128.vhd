--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : gf2_reduction_128
-- Module Name   : gf2_reduction_128 - Behavioral
-- Tool Version  : Vivado 2025.1
-- Description   : Polynomial reduction of a 255-bit unreduced GF(2)[x]
--                 product modulo the irreducible polynomial of GF(2^128).
--                 For each high bit k in 254..128, if set, XORs the
--                 low-degree polynomial FIELD_POLY_LOW shifted into
--                 positions (k - 128 + t) for every set t in
--                 FIELD_POLY_LOW. The default FIELD_POLY_LOW encodes the
--                 GHASH polynomial x^128 + x^7 + x^2 + x + 1 (the x^128
--                 term is implicit; only the low-degree part is stored).
--                 Output is a 128-bit field element. Purely combinational.
-- Dependencies  : ieee.std_logic_1164
-- Revision      : 0.01 - May 2026 - File created
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity GF2_Reduction_128 is
    generic (
        FIELD_POLY_LOW : std_logic_vector(127 downto 0) :=
            (7 => '1', 2 => '1', 1 => '1', 0 => '1', others => '0')
    );
    port (
        i_P : in  std_logic_vector(254 downto 0);
        o_C : out std_logic_vector(127 downto 0)
    );
end entity;

architecture Behavioral of GF2_Reduction_128 is
begin

    p_REDUCE : process(i_P)
        variable v_red : std_logic_vector(254 downto 0);
    begin
        v_red := i_P;

        for k in 254 downto 128 loop
            if v_red(k) = '1' then
                v_red(k) := '0';

                for t in 0 to 127 loop
                    if FIELD_POLY_LOW(t) = '1' then
                        v_red(k - 128 + t) := v_red(k - 128 + t) xor '1';
                    end if;
                end loop;
            end if;
        end loop;

        o_C <= v_red(127 downto 0);
    end process;

end architecture;