--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : gf2_multiplier_128
-- Module Name   : gf2_multiplier_128 - Behavioral
-- Tool Version  : Vivado 2025.1
-- Description   : Field multiplier over GF(2^128), used by GHASH. Wires a
--                 128x128 carry-less Karatsuba multiplier (gf2_karatsuba_128)
--                 into a polynomial reducer (gf2_reduction_128) that folds
--                 the 255-bit product modulo the GHASH irreducible polynomial
--                 x^128 + x^7 + x^2 + x + 1 (encoded by the FIELD_POLY_LOW
--                 generic). Output is a 128-bit field element. Purely
--                 combinational.
-- Dependencies  : ieee.std_logic_1164, work.gf2_karatsuba_128,
--                 work.gf2_reduction_128
-- Revision      : 0.01 - May 2026 - File created
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity GF2_Multiplier_128 is
    generic (
        FIELD_POLY_LOW : std_logic_vector(127 downto 0) :=
            (7 => '1', 2 => '1', 1 => '1', 0 => '1', others => '0')
    );
    port (
        i_A : in  std_logic_vector(127 downto 0);
        i_B : in  std_logic_vector(127 downto 0);
        o_C : out std_logic_vector(127 downto 0)
    );
end entity;

architecture Behavioral of GF2_Multiplier_128 is

    signal w_prod : std_logic_vector(254 downto 0);

begin

    u_mult : entity work.GF2_Karatsuba_128
        port map (
            i_A => i_A,
            i_B => i_B,
            o_P => w_prod
        );

    u_red : entity work.GF2_Reduction_128
        generic map (
            FIELD_POLY_LOW => FIELD_POLY_LOW
        )
        port map (
            i_P => w_prod,
            o_C => o_C
        );

end architecture;