----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_ecdh_latencija
-- Module Name   : tb_ecdh_latencija - sim
-- Tool Version  : Vivado Simulator 2025.1 (xvhdl -2008 / xelab / xsim)
--
-- Description   : Cycle-accurate latency measurement for one scalar multiplication
--                 (kP) on either ECDH core. G_LOW_LATENCY selects the device under
--                 test exactly the way ecdh_axis_ip does, so the same generic value
--                 means the same core in simulation and in synthesis:
--                   false -> ecdh_core_basic          (phase 1, one field ALU)
--                   true  -> ecdh_core_low_latency    (phase 2, three multipliers)
--
--                 Both cores expose an identical interface, so the two branches
--                 share the stimulus. The count is the number of rising clock
--                 edges from the edge that accepts i_start to the edge on which
--                 o_done is asserted, which is the figure the thesis needs to turn
--                 a measured Fmax into a time per kP.
--
--                 Vectors come from the ec_ladder.py golden model, same format the
--                 other ladder testbenches use:
--                   "<k> <x> <y> <b> <X1> <Z1> <X2> <Z2> <xa> <ya>"
--                 Only k, x, y, b are driven; xa and ya are checked, so a wrong
--                 result can never be reported as a valid latency.
--
-- Usage         : xvhdl -2008 -work work <sources in package_ecdh_ip.tcl order> \
--                        sim/tb_ecdh_latencija.vhd
--                 xelab -O3 work.tb_ecdh_latencija -s sim_f1_d32 \
--                       -generic_top "G_M=571" -generic_top "G_D=32" \
--                       -generic_top "G_LOW_LATENCY=false"
--                 xsim sim_f1_d32 -runall
--
-- Output        : one machine-readable line per vector, grepped by
--                 ECDH/Scripts/sim_ecdh_latencija.sh:
--                   CSV,<faza>,<G_D>,<q>,<bitlen_k>,<taktova_kP>,<status>
--
-- Notes         : The vector file is opened by bare name, so the runner copies it
--                 into the working directory first. The testbench calls
--                 std.env.finish, because xsim -runall does not stop on its own.
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_ecdh_latencija is
    generic (
        G_M            : integer := 571;
        G_D            : integer := 32;
        G_LOW_LATENCY  : boolean := false;                  -- false = phase 1, true = phase 2
        G_MAX_VEC      : integer := 1;                      -- vectors to measure, 1 is enough
        G_VEC_FILE     : string  := "ladder_vec.txt"        -- runner copies the file to this name
    );
end entity;

architecture sim of tb_ecdh_latencija is

    -- Field polynomial, same table the other ladder testbenches carry.
    function f_poly (m : integer) return std_logic_vector is
        variable v : std_logic_vector(m downto 0) := (others => '0');
    begin
        v(m) := '1';
        if m = 4 then
            v(1) := '1'; v(0) := '1';
        elsif m = 571 then
            v(10) := '1'; v(5) := '1'; v(2) := '1'; v(0) := '1';
        else
            report "f_poly: unknown field m=" & integer'image(m) severity failure;
        end if;
        return v;
    end function;

    -- Digit count of the serial multiplier: q = ceil(m / D). Reported alongside
    -- the measurement so the ~6q and ~2q per ladder step models can be checked
    -- without recomputing anything downstream.
    constant c_Q : integer := (G_M + G_D - 1) / G_D;

    -- Timeout guard. Phase 1 needs about 6*q cycles per ladder step over m steps;
    -- 20*m*q leaves better than a factor of three of headroom at every G_D.
    constant c_TIMEOUT : integer := 20 * G_M * c_Q + 200000;

    -- Phase label used in the output line: 1 = basic core, 2 = low latency core.
    function faza_str (ll : boolean) return string is
    begin
        if ll then return "2"; else return "1"; end if;
    end function;

    constant c_FAZA : string := faza_str(G_LOW_LATENCY);

    signal clk    : std_logic := '0';
    signal rstn   : std_logic := '0';
    signal done_s : boolean   := false;

    signal start        : std_logic := '0';
    signal k, xb, yb, b : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal ox, oy       : std_logic_vector(G_M-1 downto 0);
    signal busy, done   : std_logic;

begin

    clk <= not clk after 5 ns when not done_s else '0';

    ----------------------------------------------------------------------------
    -- Device under test. The label spans both branches in VHDL-2008, so the
    -- hierarchical name alone never proves which core was elaborated; the
    -- reported faza field is the authoritative record.
    ----------------------------------------------------------------------------
    gen_low_latency : if G_LOW_LATENCY generate
        u_dut : entity work.ecdh_core_low_latency
            generic map (G_M => G_M, G_D => G_D, G_F => f_poly(G_M))
            port map (
                i_clk => clk, i_resetn => rstn, i_start => start,
                i_k => k, i_xb => xb, i_yb => yb, i_b => b,
                o_x => ox, o_y => oy,
                o_busy => busy, o_done => done
            );
    else generate
        u_dut : entity work.ecdh_core_basic
            generic map (G_M => G_M, G_D => G_D, G_F => f_poly(G_M))
            port map (
                i_clk => clk, i_resetn => rstn, i_start => start,
                i_k => k, i_xb => xb, i_yb => yb, i_b => b,
                o_x => ox, o_y => oy,
                o_busy => busy, o_done => done
            );
    end generate;

    p_main : process
        file     f_vec : text;
        variable l     : line;
        variable v_out : line;
        variable c     : character;
        variable ok    : boolean;
        variable vk, vx, vy, vb : std_logic_vector(G_M-1 downto 0);
        variable vskip          : std_logic_vector(G_M-1 downto 0);
        variable exa, eya       : std_logic_vector(G_M-1 downto 0);
        variable v_cycles : integer;
        variable v_bitlen : integer;
        variable n        : integer := 0;

        procedure read_bits (variable ln : inout line;
                             v : out std_logic_vector) is
            variable ch  : character;
            variable okc : boolean;
        begin
            for i in v'range loop
                read(ln, ch, okc);
                assert okc report "short line in vector file" severity failure;
                if ch = '1' then v(i) := '1'; else v(i) := '0'; end if;
            end loop;
        end procedure;

        -- Position of the most significant set bit, one-based. The cores align the
        -- scalar first (S_ALIGN), so the iteration count follows the real length of
        -- k and not the field width; recording it keeps rows comparable.
        function bitlen (v : std_logic_vector) return integer is
        begin
            for i in v'high downto v'low loop
                if v(i) = '1' then
                    return i + 1;
                end if;
            end loop;
            return 0;
        end function;
    begin
        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        wait until rising_edge(clk);

        file_open(f_vec, G_VEC_FILE, read_mode);
        while not endfile(f_vec) and n < G_MAX_VEC loop
            readline(f_vec, l);
            next when l'length = 0;
            read_bits(l, vk);    read(l, c, ok);
            read_bits(l, vx);    read(l, c, ok);
            read_bits(l, vy);    read(l, c, ok);
            read_bits(l, vb);    read(l, c, ok);
            read_bits(l, vskip); read(l, c, ok);   -- X1
            read_bits(l, vskip); read(l, c, ok);   -- Z1
            read_bits(l, vskip); read(l, c, ok);   -- X2
            read_bits(l, vskip); read(l, c, ok);   -- Z2
            read_bits(l, exa);   read(l, c, ok);
            read_bits(l, eya);

            v_bitlen := bitlen(vk);

            k <= vk;  xb <= vx;  yb <= vy;  b <= vb;
            start <= '1';
            wait until rising_edge(clk);          -- this edge accepts i_start
            start <= '0';

            -- Count every edge from the one that accepted the request up to and
            -- including the edge on which o_done is high.
            v_cycles := 1;
            loop
                wait until rising_edge(clk);
                v_cycles := v_cycles + 1;
                exit when done = '1';
                assert v_cycles < c_TIMEOUT
                    report "TIMEOUT: no o_done after " & integer'image(c_TIMEOUT)
                         & " cycles (phase " & c_FAZA & ", D=" & integer'image(G_D) & ")"
                    severity failure;
            end loop;

            -- One machine-readable line; the runner greps for this prefix.
            write(v_out, string'("CSV,"));
            write(v_out, c_FAZA);                    write(v_out, string'(","));
            write(v_out, G_D);                       write(v_out, string'(","));
            write(v_out, c_Q);                       write(v_out, string'(","));
            write(v_out, v_bitlen);                  write(v_out, string'(","));
            write(v_out, v_cycles);                  write(v_out, string'(","));
            if ox = exa and oy = eya then
                write(v_out, string'("OK"));
            else
                write(v_out, string'("FAIL"));
            end if;
            writeline(output, v_out);

            n := n + 1;
            wait until rising_edge(clk);
        end loop;
        file_close(f_vec);

        assert n > 0 report "no vector was measured" severity failure;

        done_s <= true;
        wait for 100 ns;
        finish;
    end process;

end architecture;
