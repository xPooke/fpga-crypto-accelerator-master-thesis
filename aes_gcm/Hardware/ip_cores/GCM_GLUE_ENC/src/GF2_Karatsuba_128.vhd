--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : gf2_karatsuba_128
-- Module Name   : gf2_karatsuba_128 - Behavioral
-- Tool Version  : Vivado 2025.1
-- Description   : 128x128 carry-less (GF(2)) polynomial multiplication using
--                 one level of Karatsuba decomposition. Inputs A, B (128 bits)
--                 are split as A = A1*x^64 + A0, B = B1*x^64 + B0, and the
--                 product A*B = P1*x^128 + PM*x^64 + P0 is computed from
--                 three 64x64 polynomial multiplies, each delegated to an
--                 instance of gf2_karatsuba_64:
--                   P0 = A0*B0
--                   P1 = A1*B1
--                   PM = (A0+A1)*(B0+B1) + P0 + P1
--                 Output is a 255-bit unreduced polynomial product (must be
--                 folded modulo the GHASH irreducible polynomial in a
--                 separate stage — see gf2_multiplier_128 / gf2_reduction_128).
--                 Purely combinational.
-- Dependencies  : ieee.std_logic_1164, work.gf2_karatsuba_64
-- Revision      : 0.01 - May 2026 - File created
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity GF2_Karatsuba_128 is
    port (
        i_A : in  std_logic_vector(127 downto 0);
        i_B : in  std_logic_vector(127 downto 0);
        o_P : out std_logic_vector(254 downto 0)
    );
end entity;

architecture Behavioral of GF2_Karatsuba_128 is

    signal w_a0 : std_logic_vector(63 downto 0);
    signal w_a1 : std_logic_vector(63 downto 0);
    signal w_b0 : std_logic_vector(63 downto 0);
    signal w_b1 : std_logic_vector(63 downto 0);

    signal w_ax : std_logic_vector(63 downto 0);
    signal w_bx : std_logic_vector(63 downto 0);

    signal w_p0 : std_logic_vector(126 downto 0);
    signal w_p1 : std_logic_vector(126 downto 0);
    signal w_p2 : std_logic_vector(126 downto 0);

begin

    w_a0 <= i_A(63 downto 0);
    w_a1 <= i_A(127 downto 64);

    w_b0 <= i_B(63 downto 0);
    w_b1 <= i_B(127 downto 64);

    w_ax <= w_a0 xor w_a1;
    w_bx <= w_b0 xor w_b1;

    u_p0 : entity work.GF2_Karatsuba_64
        port map (
            i_A => w_a0,
            i_B => w_b0,
            o_P => w_p0
        );

    u_p1 : entity work.GF2_Karatsuba_64
        port map (
            i_A => w_a1,
            i_B => w_b1,
            o_P => w_p1
        );

    u_p2 : entity work.GF2_Karatsuba_64
        port map (
            i_A => w_ax,
            i_B => w_bx,
            o_P => w_p2
        );

    p_COMBINE : process(w_p0, w_p1, w_p2)
        variable v_PM : std_logic_vector(126 downto 0);
        variable v_R  : std_logic_vector(254 downto 0);
    begin
        v_PM := w_p2 xor w_p1 xor w_p0;

        v_R := (others => '0');

        -- P0
        v_R(126 downto 0) := v_R(126 downto 0) xor w_p0;

        -- PM << 64
        v_R(190 downto 64) := v_R(190 downto 64) xor v_PM;

        -- P1 << 128
        v_R(254 downto 128) := v_R(254 downto 128) xor w_p1;

        o_P <= v_R;
    end process;

end architecture;