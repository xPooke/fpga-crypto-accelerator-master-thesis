----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : util_split
-- Module Name   : util_split (package)
-- Tool Version  : Vivado 2025.1
--
-- Description   : Compile-time helper functions for SPLIT_demux (beat/gap/keep
--                 arithmetic). Pure functions, no state.
--
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package util_split is
    function calc_beats (constant bytes : positive; constant width : positive) return positive;
    function clog2      (constant N : positive) return positive;
    function max        (constant A, B : positive) return positive;
    function is_aligned (constant bytes : positive; constant width : positive) return boolean;
    function calc_gap   (constant bytes : natural;  constant width : positive) return natural;
    function keep_mask  (constant N : natural; constant BUS_BYTES : positive) return std_logic_vector;
    function keep_bytes (constant K : std_logic_vector) return natural;
end package;

package body util_split is

    -- Number of beats needed to carry BYTES over a DATA_WIDTH-bit bus (ceil).
    function calc_beats (constant bytes : positive; constant width : positive) return positive is
        constant BUS_BYTES : positive := width / 8;
    begin
        return (bytes + BUS_BYTES - 1) / BUS_BYTES;
    end function;

    function clog2 (constant N : positive) return positive is
        variable v_bits : positive := 1;
    begin
        while 2**v_bits < N loop
            v_bits := v_bits + 1;
        end loop;
        return v_bits;
    end function;

    function max (constant A, B : positive) return positive is
    begin
        if A > B then return A; else return B; end if;
    end function;

    function is_aligned (constant bytes : positive; constant width : positive) return boolean is
        constant BUS_BYTES : positive := width / 8;
    begin
        return (bytes mod BUS_BYTES) = 0;
    end function;

    -- Bytes left over in the straddling beat after BYTES total bytes, i.e. how
    -- many bytes of the NEXT segment already sit in that beat (0 if aligned).
    function calc_gap (constant bytes : natural; constant width : positive) return natural is
        constant BUS_BYTES : positive := width / 8;
    begin
        return (BUS_BYTES - (bytes mod BUS_BYTES)) mod BUS_BYTES;
    end function;

    -- tkeep mask with the N low bytes marked valid.
    function keep_mask (constant N : natural; constant BUS_BYTES : positive)
        return std_logic_vector is
        variable v_mask : std_logic_vector(BUS_BYTES-1 downto 0) := (others => '0');
    begin
        for i in 0 to BUS_BYTES-1 loop
            if i < N then v_mask(i) := '1'; end if;
        end loop;
        return v_mask;
    end function;

    -- Number of kept (valid) bytes in a tkeep (partial last beat is LSB-filled).
    function keep_bytes (constant K : std_logic_vector) return natural is
        variable v_n : natural := 0;
    begin
        for i in K'range loop
            if K(i) = '1' then v_n := v_n + 1; end if;
        end loop;
        return v_n;
    end function;

end package body;
