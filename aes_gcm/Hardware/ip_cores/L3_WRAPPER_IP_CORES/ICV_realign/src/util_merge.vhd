----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : util_merge
-- Module Name   : util_merge (package)
-- Tool Version  : Vivado 2025.1
--
-- Description   : Helper functions for MERGE_mux (clog2 + TKEEP byte packer
--                 helpers). Pure functions, no state.
--
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package util_merge is
    function clog2      (constant n : positive) return positive;
    function keep_bytes (constant keep : std_logic_vector) return natural;
    function keep_mask  (constant n : natural; constant bus_bytes : positive) return std_logic_vector;
    function mask_bytes (constant data : std_logic_vector; constant keep : std_logic_vector)
        return std_logic_vector;
end package;

package body util_merge is

    function clog2 (constant n : positive) return positive is
        variable v_bits : positive := 1;
    begin
        while 2**v_bits < n loop
            v_bits := v_bits + 1;
        end loop;
        return v_bits;
    end function;

    -- Number of kept (valid) bytes in a tkeep (contiguous, LSB-filled).
    function keep_bytes (constant keep : std_logic_vector) return natural is
        variable v_n : natural := 0;
    begin
        for i in keep'range loop
            if keep(i) = '1' then v_n := v_n + 1; end if;
        end loop;
        return v_n;
    end function;

    -- tkeep mask with the n low bytes marked valid.
    function keep_mask (constant n : natural; constant bus_bytes : positive)
        return std_logic_vector is
        variable v_mask : std_logic_vector(bus_bytes-1 downto 0) := (others => '0');
    begin
        for i in 0 to bus_bytes-1 loop
            if i < n then v_mask(i) := '1'; end if;
        end loop;
        return v_mask;
    end function;

    -- Zero out the bytes of DATA whose KEEP bit is '0' (kills padding garbage).
    function mask_bytes (constant data : std_logic_vector; constant keep : std_logic_vector)
        return std_logic_vector is
        variable v_out : std_logic_vector(data'range) := (others => '0');
    begin
        for i in keep'range loop
            if keep(i) = '1' then
                v_out(i*8+7 downto i*8) := data(i*8+7 downto i*8);
            end if;
        end loop;
        return v_out;
    end function;

end package body;
