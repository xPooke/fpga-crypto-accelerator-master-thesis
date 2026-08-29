----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : gf_alu_pkg
-- Module Name   : gf_alu_pkg - package
-- Tool Version  : Vivado 2025.1
--
-- Description   : Shared types and helpers for the GF(2^m) ALU and its clients.
--                 alu_op_t is the operation set of the ALU: ADD/SQR are
--                 combinational, MUL/INV are sequential (start/busy/done
--                 handshake).
--
-- Dependencies  : (none)
--
-- Revision      :
--   0.01 - June 2026 - File Created
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

package gf_alu_pkg is

    type alu_op_t is (ALU_ADD, ALU_SQR, ALU_MUL, ALU_INV);

    -- Number of bits needed to represent n (n >= 1): num_bits(4) = 3.
    -- Shared counter/index sizing helper (gf_mul digit counter, gf_inv
    -- exponent walk) — single source of truth, do not re-declare locally.
    function num_bits(n : integer) return integer;

end package;


package body gf_alu_pkg is

    function num_bits(n : integer) return integer is
        variable v_result : integer := 0;
        variable v_temp   : integer := n;
    begin
        while v_temp > 0 loop
            v_result := v_result + 1;
            v_temp   := v_temp / 2;
        end loop;
        return v_result;
    end function;

end package body;
