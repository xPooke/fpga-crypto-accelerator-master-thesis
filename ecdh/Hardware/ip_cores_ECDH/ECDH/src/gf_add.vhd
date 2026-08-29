----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : gf_add
-- Module Name   : gf_add - Behavioral
-- Tool Version  : Vivado 2025.1
--
-- Description   : GF(2^m) addition. In a characteristic-2 field addition =
--                 subtraction = bitwise XOR (coefficients mod 2, no carry).
--                 Purely combinational: m independent XOR gates, one LUT level
--                 regardless of m. Registering is left to the consumer
--                 (ALU / ladder).
--
-- Dependencies  : (none)
--
-- Revision      :
--   0.01 - June 2026 - File Created
--
-- Additional Comments :
--   Combinational, constant time (independent of operand values).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity gf_add is
    generic (
        G_M : integer := 4
    );
    port (
        i_a   : in  std_logic_vector(G_M-1 downto 0);
        i_b   : in  std_logic_vector(G_M-1 downto 0);
        o_sum : out std_logic_vector(G_M-1 downto 0)
    );
end entity;

architecture Behavioral of gf_add is
begin

    o_sum <= i_a xor i_b;

end architecture;
