--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : gf2_karatsuba_32
-- Module Name   : gf2_karatsuba_32 - Behavioral
-- Tool Version  : Vivado 2025.1
-- Description   : 32x32 carry-less (GF(2)) polynomial multiplication using
--                 one level of Karatsuba decomposition. Inputs A, B (32 bits)
--                 are split as A = A1*x^16 + A0, B = B1*x^16 + B0, and the
--                 product A*B = P1*x^32 + PM*x^16 + P0 is computed from
--                 three 16x16 polynomial multiplies, each delegated to an
--                 instance of gf2_karatsuba_16:
--                   P0 = A0*B0
--                   P1 = A1*B1
--                   PM = (A0+A1)*(B0+B1) + P0 + P1
--                 Output is a 63-bit unreduced polynomial product. Used by
--                 gf2_karatsuba_64. Purely combinational; no reduction stage.
-- Dependencies  : ieee.std_logic_1164, work.gf2_karatsuba_16
-- Revision      : 0.01 - May 2026 - File created
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity GF2_Karatsuba_32 is
    port (
        i_A : in  std_logic_vector(31 downto 0);
        i_B : in  std_logic_vector(31 downto 0);
        o_P : out std_logic_vector(62 downto 0)
    );
end entity;

architecture Behavioral of GF2_Karatsuba_32 is

    signal w_p0 : std_logic_vector(30 downto 0);
    signal w_p1 : std_logic_vector(30 downto 0);
    signal w_p2 : std_logic_vector(30 downto 0);

    signal w_ax : std_logic_vector(15 downto 0);
    signal w_bx : std_logic_vector(15 downto 0);

begin

    -- Shared XOR operands for the cross-product instance
    w_ax <= i_A(15 downto 0) xor i_A(31 downto 16);
    w_bx <= i_B(15 downto 0) xor i_B(31 downto 16);

    u_p0 : entity work.GF2_Karatsuba_16
        port map (
            i_A => i_A(15 downto 0),
            i_B => i_B(15 downto 0),
            o_P => w_p0
        );

    u_p1 : entity work.GF2_Karatsuba_16
        port map (
            i_A => i_A(31 downto 16),
            i_B => i_B(31 downto 16),
            o_P => w_p1
        );

    u_p2 : entity work.GF2_Karatsuba_16
        port map (
            i_A => w_ax,
            i_B => w_bx,
            o_P => w_p2
        );

    p_COMBINE : process(w_p0, w_p1, w_p2)
        variable v_PM : std_logic_vector(30 downto 0);
        variable v_R  : std_logic_vector(62 downto 0);
    begin
        v_PM := w_p2 xor w_p1 xor w_p0;

        v_R := (others => '0');
        v_R(30 downto 0)  := v_R(30 downto 0) xor w_p0;    -- P0
        v_R(46 downto 16) := v_R(46 downto 16) xor v_PM;   -- PM << 16
        v_R(62 downto 32) := v_R(62 downto 32) xor w_p1;   -- P1 << 32

        o_P <= v_R;
    end process;

end architecture;
