----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_ICV_realign
-- Module Name   : tb_ICV_realign - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Self-checking testbench for ICV_realign. The AXIS master drives
--                   AAD_BEATS full beats  ||  CT || ICV packed contiguously
--                 with TLAST on the last beat, which is exactly what SPLIT_demux
--                 hands to the decrypt path.
--                 The TB is the AXIS slave on m_axis and checks that the core
--                 re-aligns it into what gcm_dec_glue needs:
--                   * the AAD beats come back untouched,
--                   * the CT bytes follow, last beat partial (marked by TKEEP),
--                   * the ICV sits ALONE on the final beat, full, with TLAST.
--                 TVALID (master) and TREADY (sink) are randomly gated at
--                 P_VALID / P_READY percent. Prints "RESULT: PASS/FAIL".
--
-- Dependencies  : work.ICV_realign, ieee.math_real, std.env
--
-- Revision      :
--   0.01 - July 2026 - File Created
--
-- Additional Comments :
--   Active-low reset. All generics passed on the GHDL command line (-g...).
--   CT_BYTES = 0 exercises the degenerate case where the segment is only the tag.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;

entity tb_ICV_realign is
    generic (
        DATA_WIDTH : positive := 128;
        AAD_BEATS  : natural  := 2;
        CT_BYTES   : natural  := 40;
        P_VALID    : integer  := 100;   -- master TVALID assert probability [%]
        P_READY    : integer  := 100;   -- sink   TREADY assert probability [%]
        SEED1      : integer  := 1;
        SEED2      : integer  := 7;
        DEBUG      : integer  := 0
    );
end entity;

architecture sim of tb_ICV_realign is

    constant c_BUS_BYTES : positive := DATA_WIDTH / 8;
    constant c_ICV_BYTES : positive := c_BUS_BYTES;                 -- tag = one full beat
    constant c_SEG_BYTES : positive := CT_BYTES + c_ICV_BYTES;      -- CT || ICV, contiguous
    constant c_IN_BEATS  : positive := (c_SEG_BYTES + c_BUS_BYTES - 1) / c_BUS_BYTES;
    constant c_CT_BEATS  : natural  := (CT_BYTES + c_BUS_BYTES - 1) / c_BUS_BYTES;

    -- Expected output beats: AAD passthrough + CT beats + one ICV beat.
    constant c_OUT_BEATS : positive := AAD_BEATS + c_CT_BEATS + 1;

    type byte_arr_t is array(natural range <>) of std_logic_vector(7 downto 0);

    -- Independent patterns so a mix-up between the segments is caught.
    function pat_aad(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((i*7 + 13) mod 256, 8));
    end function;

    function pat_ct(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((i*3 + 100) mod 256, 8));
    end function;

    function pat_icv(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((i*11 + 200) mod 256, 8));
    end function;

    -- The contiguous CT || ICV byte stream the master drives after the AAD.
    function seg_byte(i : natural) return std_logic_vector is
    begin
        if i < CT_BYTES then
            return pat_ct(i);
        else
            return pat_icv(i - CT_BYTES);
        end if;
    end function;

    function keep_of(n : natural) return std_logic_vector is
        variable v_k : std_logic_vector(c_BUS_BYTES-1 downto 0) := (others => '0');
    begin
        for i in 0 to c_BUS_BYTES-1 loop
            if i < n then
                v_k(i) := '1';
            end if;
        end loop;
        return v_k;
    end function;

    function n_keep(k : std_logic_vector) return natural is
        variable v_n : natural := 0;
    begin
        for i in k'range loop
            if k(i) = '1' then
                v_n := v_n + 1;
            end if;
        end loop;
        return v_n;
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

    -- Sink bookkeeping (written by p_SINK only, read by p_CHECK)
    signal r_beats     : natural := 0;
    signal r_bytes     : natural := 0;
    signal r_errors    : natural := 0;
    signal r_last_seen : natural := 0;
    signal r_done      : boolean := false;

begin

    clk <= not clk after 5 ns;

    u_dut : entity work.ICV_realign
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            AAD_BEATS  => AAD_BEATS)
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
    -- AXIS master: AAD_BEATS full beats, then CT || ICV packed contiguously.
    ----------------------------------------------------------------------------
    p_DRIVE : process
        variable v_seed1 : positive := SEED1;
        variable v_seed2 : positive := SEED2;
        variable v_rand  : real;
        variable v_beat  : std_logic_vector(DATA_WIDTH-1 downto 0);
        variable v_idx   : natural;
        variable v_n     : natural;
    begin
        wait until rstn = '1';
        wait until rising_edge(clk);

        -- AAD: full beats, passed through untouched
        for b in 0 to AAD_BEATS-1 loop
            for l in 0 to c_BUS_BYTES-1 loop
                v_beat(8*l+7 downto 8*l) := pat_aad(b * c_BUS_BYTES + l);
            end loop;
            s_axis_tdata  <= v_beat;
            s_axis_tkeep  <= (others => '1');
            s_axis_tlast  <= '0';
            s_axis_tvalid <= '1';
            loop
                wait until rising_edge(clk);
                exit when s_axis_tready = '1';
            end loop;
            s_axis_tvalid <= '0';

            uniform(v_seed1, v_seed2, v_rand);
            if integer(v_rand * 100.0) >= P_VALID then
                wait until rising_edge(clk);
            end if;
        end loop;

        -- CT || ICV: contiguous, TLAST on the final beat
        for b in 0 to c_IN_BEATS-1 loop
            v_beat := (others => '0');
            v_idx  := b * c_BUS_BYTES;
            if c_SEG_BYTES - v_idx >= c_BUS_BYTES then
                v_n := c_BUS_BYTES;
            else
                v_n := c_SEG_BYTES - v_idx;
            end if;
            for l in 0 to v_n-1 loop
                v_beat(8*l+7 downto 8*l) := seg_byte(v_idx + l);
            end loop;

            s_axis_tdata <= v_beat;
            s_axis_tkeep <= keep_of(v_n);
            if b = c_IN_BEATS-1 then
                s_axis_tlast <= '1';
            else
                s_axis_tlast <= '0';
            end if;
            s_axis_tvalid <= '1';
            loop
                wait until rising_edge(clk);
                exit when s_axis_tready = '1';
            end loop;
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';

            uniform(v_seed1, v_seed2, v_rand);
            if integer(v_rand * 100.0) >= P_VALID then
                wait until rising_edge(clk);
            end if;
        end loop;

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
    -- AXIS slave: check every beat against the expected re-aligned stream.
    ----------------------------------------------------------------------------
    p_SINK : process(clk)
        variable v_beat : natural := 0;
        variable v_cnt  : natural := 0;
        variable v_byt  : natural := 0;
        variable v_err  : natural := 0;
        variable v_lst  : natural := 0;
        variable v_k    : natural;
        variable v_exp  : std_logic_vector(7 downto 0);
        variable v_got  : std_logic_vector(7 downto 0);
        variable v_base : natural;
    begin
        if rising_edge(clk) then
            if rstn = '1' and m_axis_tvalid = '1' and m_axis_tready = '1' then
                v_beat := v_cnt;
                v_k    := n_keep(m_axis_tkeep);

                if v_beat < AAD_BEATS then
                    ------------------------------------------------------------
                    -- AAD beat: untouched, full, no TLAST
                    ------------------------------------------------------------
                    if v_k /= c_BUS_BYTES then
                        report "AAD beat " & integer'image(v_beat) & " is not full (keep="
                             & integer'image(v_k) & ")" severity error;
                        v_err := v_err + 1;
                    end if;
                    for l in 0 to c_BUS_BYTES-1 loop
                        v_exp := pat_aad(v_beat * c_BUS_BYTES + l);
                        v_got := m_axis_tdata(8*l+7 downto 8*l);
                        if v_got /= v_exp then
                            report "AAD mismatch beat " & integer'image(v_beat)
                                 & " lane " & integer'image(l) severity error;
                            v_err := v_err + 1;
                        end if;
                    end loop;
                    if m_axis_tlast = '1' then
                        report "TLAST asserted on an AAD beat" severity error;
                        v_err := v_err + 1;
                    end if;

                elsif v_beat < AAD_BEATS + c_CT_BEATS then
                    ------------------------------------------------------------
                    -- CT beat: full, except the last one which carries the tail
                    ------------------------------------------------------------
                    v_base := (v_beat - AAD_BEATS) * c_BUS_BYTES;
                    if v_beat = AAD_BEATS + c_CT_BEATS - 1 then
                        if v_k /= CT_BYTES - v_base then
                            report "CT tail beat keeps " & integer'image(v_k)
                                 & " bytes, expected " & integer'image(CT_BYTES - v_base)
                                 severity error;
                            v_err := v_err + 1;
                        end if;
                    elsif v_k /= c_BUS_BYTES then
                        report "CT beat " & integer'image(v_beat) & " is not full"
                             severity error;
                        v_err := v_err + 1;
                    end if;

                    for l in 0 to v_k-1 loop
                        v_exp := pat_ct(v_base + l);
                        v_got := m_axis_tdata(8*l+7 downto 8*l);
                        if v_got /= v_exp then
                            report "CT mismatch byte " & integer'image(v_base + l)
                                 severity error;
                            v_err := v_err + 1;
                        end if;
                    end loop;
                    if m_axis_tlast = '1' then
                        report "TLAST asserted on a CT beat" severity error;
                        v_err := v_err + 1;
                    end if;

                else
                    ------------------------------------------------------------
                    -- ICV beat: alone, full, TLAST. This is the whole point.
                    ------------------------------------------------------------
                    if v_k /= c_BUS_BYTES then
                        report "ICV beat is not a full beat (keep=" & integer'image(v_k)
                             & ")" severity error;
                        v_err := v_err + 1;
                    end if;
                    for l in 0 to c_BUS_BYTES-1 loop
                        v_exp := pat_icv(l);
                        v_got := m_axis_tdata(8*l+7 downto 8*l);
                        if v_got /= v_exp then
                            report "ICV mismatch lane " & integer'image(l) severity error;
                            v_err := v_err + 1;
                        end if;
                    end loop;
                    if m_axis_tlast /= '1' then
                        report "ICV beat carries no TLAST" severity error;
                        v_err := v_err + 1;
                    end if;
                end if;

                if DEBUG = 1 then
                    report "beat " & integer'image(v_beat) & "  keep="
                         & integer'image(v_k) & "  last=" & std_logic'image(m_axis_tlast);
                end if;

                v_cnt := v_cnt + 1;
                v_byt := v_byt + v_k;
                if m_axis_tlast = '1' then
                    v_lst := v_lst + 1;
                end if;

                r_beats     <= v_cnt;
                r_bytes     <= v_byt;
                r_errors    <= v_err;
                r_last_seen <= v_lst;
                if m_axis_tlast = '1' then
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
        report "==== tb_ICV_realign  DW=" & integer'image(DATA_WIDTH)
             & "  AAD_BEATS=" & integer'image(AAD_BEATS)
             & "  CT=" & integer'image(CT_BYTES)
             & "  PV=" & integer'image(P_VALID)
             & "  PR=" & integer'image(P_READY) & " ====";

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';

        while not r_done loop
            wait until rising_edge(clk);
            v_timeout := v_timeout + 1;
            if v_timeout > 200000 then
                report "TIMEOUT - deadlock (beats=" & integer'image(r_beats) & ")"
                     severity error;
                report "RESULT: FAIL";
                finish;
            end if;
        end loop;

        -- let a spurious extra beat show up, if there is one
        for i in 1 to 20 loop
            wait until rising_edge(clk);
        end loop;

        v_fail := r_errors;

        if r_beats /= c_OUT_BEATS then
            report "beat count " & integer'image(r_beats) & ", expected "
                 & integer'image(c_OUT_BEATS) severity error;
            v_fail := v_fail + 1;
        end if;
        if r_bytes /= AAD_BEATS * c_BUS_BYTES + CT_BYTES + c_ICV_BYTES then
            report "byte count " & integer'image(r_bytes) & ", expected "
                 & integer'image(AAD_BEATS * c_BUS_BYTES + CT_BYTES + c_ICV_BYTES)
                 severity error;
            v_fail := v_fail + 1;
        end if;
        if r_last_seen /= 1 then
            report "TLAST count " & integer'image(r_last_seen) & ", expected 1"
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
