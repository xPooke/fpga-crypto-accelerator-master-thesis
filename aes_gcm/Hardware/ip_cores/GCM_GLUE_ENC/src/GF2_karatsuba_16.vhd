--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : gf2_karatsuba_16
-- Module Name   : gf2_karatsuba_16 - Behavioral
-- Tool Version  : Vivado 2025.1
-- Description   : 16x16 carry-less (GF(2)) polynomial multiplication using
--                 one level of Karatsuba decomposition. The 16-bit inputs
--                 A, B are split as A = A1*x^8 + A0, B = B1*x^8 + B0, and
--                 the product A*B = P1*x^16 + PM*x^8 + P0 is computed from
--                 three 8x8 polynomial multiplies:
--                   P0 = A0*B0
--                   P1 = A1*B1
--                   PM = (A0+A1)*(B0+B1) + P0 + P1
--                 Output is a 31-bit unreduced polynomial product. Used as
--                 a leaf block by larger Karatsuba multipliers. Purely
--                 combinational; no reduction stage.
-- Dependencies  : ieee.std_logic_1164
-- Revision      : 0.01 - May 2026 - File created
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity gf2_karatsuba_16 is
    port (
        i_A : in  std_logic_vector(15 downto 0);
        i_B : in  std_logic_vector(15 downto 0);
        o_P : out std_logic_vector(30 downto 0)
    );
end entity;

architecture Behavioral of gf2_karatsuba_16 is

    -- 8x8 GF(2) polynomial multiply
    function gf2_mul_8(
        a : std_logic_vector(7 downto 0);
        b : std_logic_vector(7 downto 0)
    ) return std_logic_vector is
        variable v_P : std_logic_vector(14 downto 0);
    begin
        v_P := (others => '0');

        for i in 0 to 7 loop
            for j in 0 to 7 loop
                v_P(i + j) := v_P(i + j) xor (a(j) and b(i));
            end loop;
        end loop;

        return v_P;
    end function;

begin

    p_MUL : process(i_A, i_B)
        variable v_A0, v_A1 : std_logic_vector(7 downto 0);
        variable v_B0, v_B1 : std_logic_vector(7 downto 0);

        variable v_P0, v_P1, v_P2 : std_logic_vector(14 downto 0);
        variable v_PM             : std_logic_vector(14 downto 0);

        variable v_R : std_logic_vector(30 downto 0);
    begin
        v_A0 := i_A(7 downto 0);
        v_A1 := i_A(15 downto 8);

        v_B0 := i_B(7 downto 0);
        v_B1 := i_B(15 downto 8);

        v_P0 := gf2_mul_8(v_A0, v_B0);
        v_P1 := gf2_mul_8(v_A1, v_B1);
        v_P2 := gf2_mul_8(v_A0 xor v_A1, v_B0 xor v_B1);

        v_PM := v_P2 xor v_P1 xor v_P0;

        v_R := (others => '0');

        -- P0
        v_R(14 downto 0) := v_R(14 downto 0) xor v_P0;

        -- PM << 8
        v_R(22 downto 8) := v_R(22 downto 8) xor v_PM;

        -- P1 << 16
        v_R(30 downto 16) := v_R(30 downto 16) xor v_P1;

        o_P <= v_R;
    end process;

end architecture;