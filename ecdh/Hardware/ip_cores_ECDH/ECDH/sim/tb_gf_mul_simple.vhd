----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_gf_mul_simple
-- Module Name   : tb_gf_mul_simple - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Minimal smoke test for gf_mul (GF(2^4), f=x^4+x+1)
--                 Drives a few hand-computed vectors, waits for o_done and prints
--                 got vs expected. NOT exhaustive -- that comes later, with the golden model.
--                 Run (Vivado xsim or GHDL):
--                 ghdl -a --std=08 src/gf_mul.vhd sim/tb_gf_mul_simple.vhd
--                 ghdl -e --std=08 tb_gf_mul_simple && ghdl -r --std=08 tb_gf_mul_simple
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gf_mul_simple is
end entity;

architecture sim of tb_gf_mul_simple is

    constant c_M : integer := 4;
    constant c_D : integer := 3;
    
    signal clk    : std_logic := '0';
    signal rstn   : std_logic := '0';
    signal start  : std_logic := '0';
    signal a      : std_logic_vector(c_M-1 downto 0) := (others => '0');
    signal b      : std_logic_vector(c_M-1 downto 0) := (others => '0');
    signal res    : std_logic_vector(c_M-1 downto 0);
    signal busy   : std_logic;
    signal done   : std_logic;

    -- (a, b, expected) in GF(2^4), f = x^4 + x + 1
    type vec_t is record
        a, b, exp : std_logic_vector(c_M-1 downto 0);
    end record;
    type vec_arr_t is array (natural range <>) of vec_t;
    constant c_VECS : vec_arr_t := (
        ("1011", "1101", "0110"),   -- A*B computed by hand
        ("0010", "0001", "0010"),   -- x * 1 = x
        ("0010", "0010", "0100"),   -- x * x = x^2
        ("1000", "0010", "0011")    -- x^3 * x = x^4 = x+1  (reduction test!)
    );

begin

    clk <= not clk after 5 ns;

    dut : entity work.gf_mul
        generic map (G_M => c_M,G_D => c_D,G_F => "10011")
        port map (
            i_clk => clk, i_resetn => rstn, i_start => start,
            i_a => a, i_b => b, o_res => res, o_busy => busy, o_done => done
        );

    p_main : process
        -- local '0'/'1' printer -- independent of tool-specific to_string(slv)
        function slv_str(v : std_logic_vector) return string is
            variable s : string(1 to v'length);
            variable k : integer := 1;
        begin
            for i in v'range loop
                if v(i) = '1' then s(k) := '1'; else s(k) := '0'; end if;
                k := k + 1;
            end loop;
            return s;
        end function;

        variable v_fail : integer := 0;
    begin
        rstn <= '0';
        wait for 40 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        for i in c_VECS'range loop
            a     <= c_VECS(i).a;
            b     <= c_VECS(i).b;
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';

            -- wait for done pulse
            for g in 0 to 100 loop
                wait until rising_edge(clk);
                exit when done = '1';
                assert g < 99 report "TIMEOUT: done never asserted" severity failure;
            end loop;

            if res = c_VECS(i).exp then
                report "OK   " & slv_str(c_VECS(i).a) & " * " & slv_str(c_VECS(i).b)
                     & " = " & slv_str(res);
            else
                v_fail := v_fail + 1;
                report "FAIL " & slv_str(c_VECS(i).a) & " * " & slv_str(c_VECS(i).b)
                     & " = " & slv_str(res) & "  (expected " & slv_str(c_VECS(i).exp) & ")"
                     severity error;
            end if;

            wait until rising_edge(clk);  -- gap between operations
        end loop;

        if v_fail = 0 then
            report "==== ALL OK ====";
        else
            report "==== " & integer'image(v_fail) & " FAIL ====" severity failure;
        end if;
        wait;
    end process;

end architecture;
