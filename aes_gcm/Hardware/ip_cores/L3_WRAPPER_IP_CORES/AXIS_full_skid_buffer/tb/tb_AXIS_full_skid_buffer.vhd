----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_AXIS_full_skid_buffer
-- Module Name   : tb_AXIS_full_skid_buffer - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Self-checking testbench for AXIS_full_skid_buffer.
--
--                 A skid buffer must be transparent: whatever goes in comes out,
--                 in order, once, with TKEEP and TLAST intact. The TB drives
--                 BEATS beats (each with its own data / keep / last pattern) and
--                 checks every output beat against the same reference, so a
--                 dropped, duplicated or re-ordered beat is caught.
--
--                 It also checks the two properties the buffer exists for:
--                   * FULL RATE - with TVALID and TREADY both held high the
--                     buffer sustains one beat per clock after the priming
--                     cycle (the one cycle of latency it costs by design),
--                   * NO READY PATH - s_axis_tready is a registered output, so
--                     it is high straight out of reset, before any handshake
--                     activity could have driven it.
--
--                 TVALID / TREADY are randomly gated at P_VALID / P_READY
--                 percent. Prints "RESULT: PASS/FAIL".
--
-- Dependencies  : work.AXIS_full_skid_buffer, ieee.math_real, std.env
--
-- Revision      :
--   0.01 - July 2026 - File Created
--
-- Additional Comments :
--   Active-low reset. All generics passed on the GHDL command line (-g...).
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;

entity tb_AXIS_full_skid_buffer is
    generic (
        DATA_WIDTH : positive := 128;
        BEATS      : positive := 64;
        P_VALID    : integer  := 100;   -- master TVALID assert probability [%]
        P_READY    : integer  := 100;   -- sink   TREADY assert probability [%]
        SEED1      : integer  := 1;
        SEED2      : integer  := 7
    );
end entity;

architecture sim of tb_AXIS_full_skid_buffer is

    constant c_BUS_BYTES : positive := DATA_WIDTH / 8;

    -- Reference beat i: a distinct data / keep / last triple.
    function ref_data(i : natural) return std_logic_vector is
        variable v : std_logic_vector(DATA_WIDTH-1 downto 0);
    begin
        for l in 0 to c_BUS_BYTES-1 loop
            v(8*l+7 downto 8*l) := std_logic_vector(to_unsigned((i*7 + l*3 + 13) mod 256, 8));
        end loop;
        return v;
    end function;

    -- Every 8th beat is partial, so TKEEP is not a constant.
    function ref_keep(i : natural) return std_logic_vector is
        variable v : std_logic_vector(c_BUS_BYTES-1 downto 0) := (others => '1');
        variable n : natural;
    begin
        if (i mod 8) = 7 then
            n := (i mod c_BUS_BYTES) + 1;
            v := (others => '0');
            for l in 0 to c_BUS_BYTES-1 loop
                if l < n then
                    v(l) := '1';
                end if;
            end loop;
        end if;
        return v;
    end function;

    -- Every 16th beat ends a packet, so TLAST is exercised too.
    function ref_last(i : natural) return std_logic is
    begin
        if (i mod 16) = 15 or i = BEATS-1 then
            return '1';
        else
            return '0';
        end if;
    end function;

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';

    signal s_axis_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0)  := (others => '0');
    signal s_axis_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0) := (others => '0');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tready : std_logic;

    signal m_axis_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal m_axis_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tlast  : std_logic;
    signal m_axis_tready : std_logic := '0';

    signal r_sent   : natural := 0;
    signal r_got    : natural := 0;
    signal r_errors : natural := 0;
    signal r_done   : boolean := false;

    -- Full-rate check: how many cycles the sink saw no beat while the source
    -- had one to give and the sink was ready.
    signal r_bubbles : natural := 0;

begin

    clk <= not clk after 5 ns;

    u_dut : entity work.AXIS_full_skid_buffer
        generic map (
            DATA_WIDTH => DATA_WIDTH)
        port map (
            i_clk  => clk,
            i_rstn => rstn,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tkeep  => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tready => s_axis_tready,
            m_axis_tdata  => m_axis_tdata,
            m_axis_tkeep  => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tlast  => m_axis_tlast,
            m_axis_tready => m_axis_tready);

    ----------------------------------------------------------------------------
    -- AXIS master
    ----------------------------------------------------------------------------
    p_DRIVE : process
        variable v_seed1 : positive := SEED1;
        variable v_seed2 : positive := SEED2;
        variable v_rand  : real;
        variable v_i     : natural := 0;
    begin
        wait until rstn = '1';
        wait until rising_edge(clk);

        while v_i < BEATS loop
            uniform(v_seed1, v_seed2, v_rand);
            if integer(v_rand * 100.0) < P_VALID then
                s_axis_tdata  <= ref_data(v_i);
                s_axis_tkeep  <= ref_keep(v_i);
                s_axis_tlast  <= ref_last(v_i);
                s_axis_tvalid <= '1';

                wait until rising_edge(clk) and s_axis_tready = '1';
                s_axis_tvalid <= '0';
                v_i           := v_i + 1;
                r_sent        <= v_i;
            else
                s_axis_tvalid <= '0';
                wait until rising_edge(clk);
            end if;
        end loop;

        s_axis_tvalid <= '0';
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Randomly gated sink TREADY
    ----------------------------------------------------------------------------
    p_SINK_READY : process
        variable v_seed1 : positive := SEED2 + 3;
        variable v_seed2 : positive := SEED1 + 11;
        variable v_rand  : real;
    begin
        wait until rising_edge(clk);
        uniform(v_seed1, v_seed2, v_rand);
        if integer(v_rand * 100.0) < P_READY then
            m_axis_tready <= '1';
        else
            m_axis_tready <= '0';
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- AXIS slave: every beat must match the reference, in order.
    ----------------------------------------------------------------------------
    p_SINK : process(clk)
        variable v_i   : natural := 0;
        variable v_err : natural := 0;
        variable v_bub : natural := 0;
    begin
        if rising_edge(clk) then
            if rstn = '1' then
                if m_axis_tvalid = '1' and m_axis_tready = '1' then
                    if v_i >= BEATS then
                        report "extra beat after the stream ended" severity error;
                        v_err := v_err + 1;
                    else
                        if m_axis_tdata /= ref_data(v_i) then
                            report "TDATA mismatch on beat " & integer'image(v_i)
                                 severity error;
                            v_err := v_err + 1;
                        end if;
                        if m_axis_tkeep /= ref_keep(v_i) then
                            report "TKEEP mismatch on beat " & integer'image(v_i)
                                 severity error;
                            v_err := v_err + 1;
                        end if;
                        if m_axis_tlast /= ref_last(v_i) then
                            report "TLAST mismatch on beat " & integer'image(v_i)
                                 severity error;
                            v_err := v_err + 1;
                        end if;
                    end if;
                    v_i := v_i + 1;

                elsif m_axis_tready = '1' and m_axis_tvalid = '0'
                      and s_axis_tvalid = '1' and v_i > 0 and v_i < BEATS then
                    -- The sink was ready and the source had a beat, yet nothing
                    -- came out. Once the first beat is through, the buffer must
                    -- never gap again at full rate. (v_i > 0 skips the priming
                    -- cycle: a skid buffer costs one cycle of latency by design.)
                    v_bub := v_bub + 1;
                end if;

                r_got     <= v_i;
                r_errors  <= v_err;
                r_bubbles <= v_bub;
                if v_i >= BEATS then
                    r_done <= true;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Verdict
    ----------------------------------------------------------------------------
    p_CHECK : process
        variable v_timeout : natural := 0;
        variable v_fail    : natural := 0;
    begin
        report "==== tb_AXIS_full_skid_buffer  DW=" & integer'image(DATA_WIDTH)
             & "  BEATS=" & integer'image(BEATS)
             & "  PV=" & integer'image(P_VALID)
             & "  PR=" & integer'image(P_READY) & " ====";

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';

        -- s_axis_tready is registered, so it must already be high out of reset,
        -- before any TVALID or TREADY activity can have influenced it.
        wait until rising_edge(clk);
        if s_axis_tready /= '1' then
            report "s_axis_tready is not high in the empty state" severity error;
            v_fail := v_fail + 1;
        end if;

        while not r_done loop
            wait until rising_edge(clk);
            v_timeout := v_timeout + 1;
            if v_timeout > 100000 then
                report "TIMEOUT - deadlock (got " & integer'image(r_got) & " of "
                     & integer'image(BEATS) & ")" severity error;
                report "RESULT: FAIL";
                finish;
            end if;
        end loop;

        for i in 1 to 20 loop
            wait until rising_edge(clk);
        end loop;

        v_fail := v_fail + r_errors;

        if r_got /= BEATS then
            report "got " & integer'image(r_got) & " beats, expected "
                 & integer'image(BEATS) severity error;
            v_fail := v_fail + 1;
        end if;

        -- One beat per clock: only meaningful when neither side throttles.
        if P_VALID = 100 and P_READY = 100 and r_bubbles /= 0 then
            report "full-rate violation: " & integer'image(r_bubbles)
                 & " bubble cycle(s) with TVALID and TREADY both high"
                 severity error;
            v_fail := v_fail + 1;
        end if;

        if v_fail = 0 then
            report "RESULT: PASS";
        else
            report "RESULT: FAIL (" & integer'image(v_fail) & " errors)";
        end if;
        finish;
    end process;

end architecture;
