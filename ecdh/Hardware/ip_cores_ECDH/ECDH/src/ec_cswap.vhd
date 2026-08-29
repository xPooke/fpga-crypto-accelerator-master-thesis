----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ec_cswap
-- Module Name   : ec_cswap - Behavioral
-- Tool Version  : Vivado 2025.1
--
-- Description   : Constant-time conditional swap of the ladder points
--                 P1=(X1,Z1) and P2=(X2,Z2) based on a scalar bit. Branch-free:
--                 the data flow is identical for swap=0 and swap=1
--                 (timing/SPA). HW version of cswap from ec_ladder.py.
--                 Spec: SPEC_ec_cswap.md
--
-- Dependencies  : (none)
--
-- Revision      :
--   0.01 - August 2026 - File Created
--
-- Additional Comments :
--   Purely combinational (like gf_add); registering is left to the consumer
--   (the scalar-mult FSM uses the module twice per bit: before and after the
--   ladder step).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity ec_cswap is
    generic (
        G_M : integer := 4
    );
    port (
        i_swap : in  std_logic;
        i_x1   : in  std_logic_vector(G_M-1 downto 0);
        i_z1   : in  std_logic_vector(G_M-1 downto 0);
        i_x2   : in  std_logic_vector(G_M-1 downto 0);
        i_z2   : in  std_logic_vector(G_M-1 downto 0);
        o_x1   : out std_logic_vector(G_M-1 downto 0);
        o_z1   : out std_logic_vector(G_M-1 downto 0);
        o_x2   : out std_logic_vector(G_M-1 downto 0);
        o_z2   : out std_logic_vector(G_M-1 downto 0)
    );
end entity;

architecture Behavioral of ec_cswap is
begin

    -- Four parallel 2:1 muxes controlled by the same scalar bit. Both mux
    -- inputs are always driven, so the data flow and timing are identical
    -- for swap=0 and swap=1 — the constant-time requirement of the ladder.
    o_x1 <= i_x2 when i_swap = '1' else i_x1;
    o_z1 <= i_z2 when i_swap = '1' else i_z1;
    o_x2 <= i_x1 when i_swap = '1' else i_x2;
    o_z2 <= i_z1 when i_swap = '1' else i_z2;

end architecture;
