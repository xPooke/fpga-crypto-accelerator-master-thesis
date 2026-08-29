----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_gf_mul_btb
-- Module Name   : tb_gf_mul_btb - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : BACK-TO-BACK (streaming) test for gf_mul
--                 Holds i_start='1' the WHOLE time and streams vectors back-to-back, to cover
--                 the S_DONE -> S_CALCULATE branch (skips S_IDLE) — no idle cycle between two
--                 multiplications. Vector format: "<a> <b> <exp>" (as in tb_gf_mul_vec).
--                 KEY (protocol): in S_DONE the DUT latches NEW i_a/i_b on the edge that ends
--                 the S_DONE cycle, so the next vector must be stable on the bus ALREADY
--                 during S_DONE — i.e. it must be applied EARLY. The TB does so as soon as the
--                 DUT accepts the current operand: o_busy 0->1 (entry into S_CALCULATE). It
--                 then applies the next vector and pushes its expected result into the
--                 scoreboard queue. Checking happens on every o_done='1' (o_res vs oldest
--                 queue entry).
--                 ghdl -r --std=08 tb_gf_mul_btb -gG_M=4   -gG_VEC_FILE=gf_vec_gf4.txt
--                 ghdl -r --std=08 tb_gf_mul_btb -gG_M=571 -gG_VEC_FILE=gf_vec_b571.txt
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_gf_mul_btb is
    generic (
        G_M        : integer := 4;
        G_D        : integer := 1;
        G_VEC_FILE : string  := "gf_vec_gf4.txt"
    );
end entity;

architecture sim of tb_gf_mul_btb is

    function f_poly(m : integer) return std_logic_vector is
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

    signal clk    : std_logic := '0';
    signal rstn   : std_logic := '0';
    signal done_s : boolean   := false;

    signal start  : std_logic := '0';
    signal a      : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal b      : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal res    : std_logic_vector(G_M-1 downto 0);
    signal busy   : std_logic;
    signal done   : std_logic;

begin

    clk <= not clk after 5 ns when not done_s else '0';

    dut : entity work.gf_mul
        generic map (G_M => G_M, G_D => G_D, G_F => f_poly(G_M))
        port map (
            i_clk => clk, i_resetn => rstn, i_start => start,
            i_a => a, i_b => b, o_res => res, o_busy => busy, o_done => done
        );

    p_main : process
        constant QD : integer := 8;        -- scoreboard queue depth
        type slv_arr is array (0 to QD-1) of std_logic_vector(G_M-1 downto 0);

        file     f_vec : text;
        variable l     : line;
        variable c     : character;
        variable ok    : boolean;
        variable va    : std_logic_vector(G_M-1 downto 0);
        variable vb    : std_logic_vector(G_M-1 downto 0);
        variable vexp  : std_logic_vector(G_M-1 downto 0);

        variable q      : slv_arr;
        variable q_head : integer := 0;
        variable q_tail : integer := 0;
        variable q_cnt  : integer := 0;

        variable prev_busy  : std_logic := '0';
        variable more_vec   : boolean   := true;   -- more vectors to launch
        variable n_launch   : integer   := 0;
        variable n_check    : integer   := 0;
        variable nfail      : integer   := 0;

        procedure read_bits(variable ln : inout line;
                            v  : out std_logic_vector) is
            variable ch : character;
            variable okc : boolean;
        begin
            for i in v'range loop
                read(ln, ch, okc);
                assert okc report "short line in vector file" severity failure;
                if ch = '1' then v(i) := '1'; else v(i) := '0'; end if;
            end loop;
        end procedure;

        -- reads one vector; good=false on endfile
        procedure read_vec(variable ga, gb, ge : out std_logic_vector;
                           variable good : out boolean) is
        begin
            good := false;
            while not endfile(f_vec) loop
                readline(f_vec, l);
                next when l'length = 0;
                read_bits(l, ga); read(l, c, ok);
                read_bits(l, gb); read(l, c, ok);
                read_bits(l, ge);
                good := true; return;
            end loop;
        end procedure;
    begin
        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;

        file_open(f_vec, G_VEC_FILE, read_mode);

        -- apply the FIRST vector before reset deassert and queue its exp
        read_vec(va, vb, vexp, more_vec);
        assert more_vec report "empty vector file" severity failure;
        a <= va; b <= vb;
        q(q_tail) := vexp; q_tail := (q_tail+1) mod QD; q_cnt := q_cnt+1;
        n_launch := 1;
        start <= '1';

        rstn <= '1';

        loop
            wait until rising_edge(clk);

            -- (1) check result on every done
            if done = '1' then
                if res /= q(q_head) then
                    nfail := nfail + 1;
                    if nfail <= 8 then
                        report "FAIL back-to-back pos " & integer'image(n_check)
                             severity error;
                    end if;
                end if;
                q_head := (q_head+1) mod QD; q_cnt := q_cnt-1;
                n_check := n_check + 1;
            end if;

            -- (2) DUT accepted current operand (busy 0->1) => apply next one EARLY
            if busy = '1' and prev_busy = '0' then
                if more_vec then
                    read_vec(va, vb, vexp, more_vec);
                    if more_vec then
                        a <= va; b <= vb;
                        q(q_tail) := vexp; q_tail := (q_tail+1) mod QD;
                        q_cnt := q_cnt+1; n_launch := n_launch+1;
                    else
                        -- no more vectors: let the last one finish, then back to S_IDLE
                        start <= '0';
                    end if;
                end if;
            end if;
            prev_busy := busy;

            exit when (not more_vec) and (q_cnt = 0);
        end loop;

        file_close(f_vec);

        assert n_check = n_launch
            report "launched " & integer'image(n_launch) & " but checked "
                 & integer'image(n_check) severity failure;

        if nfail = 0 then
            report "==== BTB ALL " & integer'image(n_check) & " PASS (m="
                 & integer'image(G_M) & ") ====";
        else
            report "==== BTB " & integer'image(nfail) & "/" & integer'image(n_check)
                 & " FAIL (m=" & integer'image(G_M) & ") ====" severity failure;
        end if;

        done_s <= true;
        wait;
    end process;

end architecture;
