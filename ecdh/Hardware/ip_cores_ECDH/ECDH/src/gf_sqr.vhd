----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : gf_sqr
-- Module Name   : gf_sqr - Behavioral
-- Tool Version  : Vivado 2025.1
--
-- Description   : GF(2^m) squaring. Squaring is linear (Frobenius, char 2):
--                 a^2 = sum a_i * x^(2i) — bit i of the input moves to position
--                 2i ("bit spreading"), then the spread polynomial (degree up
--                 to 2m-2) is reduced by the irreducible f back to m bits.
--                 Both steps are fixed and linear => a purely combinational
--                 XOR network.
--
-- Dependencies  : (none)
--
-- Revision      :
--   0.01 - June 2026 - File Created
--
-- Additional Comments :
--   Combinational, no register. For B-571 the depth is one LUT6 level
--   (analysis: ECDH_python/gf_sqr_depth.py).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity gf_sqr is
    generic (
        G_M : integer := 4;
        G_F : std_logic_vector := "10011"   -- f WITH the leading bit (G_M+1 bits)
    );
    port (
        i_a  : in  std_logic_vector(G_M-1 downto 0);
        o_sq : out std_logic_vector(G_M-1 downto 0)
    );
end entity;

architecture Behavioral of gf_sqr is

    -- position copy normalizes an unconstrained generic's (0 to m) range
    constant c_F : std_logic_vector(G_M downto 0) := G_F;

    function gf_square(a : std_logic_vector(G_M-1 downto 0)) return std_logic_vector is
        variable v_s : std_logic_vector(2*G_M-2 downto 0) := (others => '0');
    begin
        -- 1) spread: input bit i -> position 2i (odd positions stay 0)
        for i in 0 to G_M-1 loop
            v_s(2*i) := a(i);
        end loop;

        -- 2) reduce top-down: for i = 2m-2 .. m, if v_s(i)='1' XOR in f aligned
        --    so that its leading x^m lands on bit i (i.e. f << (i-m)).
        --    c_F is (G_M downto 0) = f with the leading bit; XORed into
        --    v_s(i .. i-m).
        for i in 2*G_M-2 downto G_M loop
            if v_s(i) = '1' then
                v_s(i downto i-G_M) := v_s(i downto i-G_M) xor c_F;
            end if;
        end loop;

        return v_s(G_M-1 downto 0);
    end function;

begin

    assert G_F'length = G_M + 1
        report "G_F must be the irreducible polynomial WITH its leading bit (G_M+1 bits)"
        severity failure;

    o_sq <= gf_square(i_a);

end architecture;
