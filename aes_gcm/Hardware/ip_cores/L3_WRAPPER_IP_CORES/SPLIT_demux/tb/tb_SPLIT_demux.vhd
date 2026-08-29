----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_SPLIT_demux
-- Module Name   : tb_SPLIT_demux - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Self-checking testbench for SPLIT_demux. Drives a contiguous
--                 byte stream (BYPASS_BYTES | AAD_BYTES | PT_BYTES) as an AXIS
--                 master with a deterministic byte pattern, and acts as the
--                 AXIS slave on both masters. TVALID (upstream) and TREADY
--                 (both downstreams) are randomly gated at P_VALID / P_READY
--                 percent to exercise stall / back-pressure.
--                 The byte streams are reconstructed from the output beats via
--                 TKEEP and checked against the reference model:
--                   m_bypass  = bytes[0 .. BYPASS_BYTES-1]
--                   m_crypto  = bytes[BYPASS_BYTES .. BYPASS_BYTES+AAD+PT-1]
--                 Prints "RESULT: PASS/FAIL" and calls std.env.finish.
--
-- Dependencies  : work.SPLIT_demux, ieee.math_real, std.env
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

entity tb_SPLIT_demux is
    generic (
        DATA_WIDTH   : positive := 128;
        BYPASS_BYTES : positive := 50;
        AAD_BYTES    : positive := 20;
        PT_BYTES     : positive := 40;
        P_VALID      : integer  := 100;  -- upstream TVALID assert probability [%]
        P_READY      : integer  := 100;  -- downstream TREADY assert probability [%]
        SEED1        : integer  := 1;
        SEED2        : integer  := 7;
        DEBUG        : integer  := 0
    );
end entity;

architecture sim of tb_SPLIT_demux is

    constant c_BUS_BYTES  : positive := DATA_WIDTH / 8;
    constant c_TOTAL      : positive := BYPASS_BYTES + AAD_BYTES + PT_BYTES;
    constant c_IN_BEATS   : positive := (c_TOTAL + c_BUS_BYTES - 1) / c_BUS_BYTES;
    constant c_CRYPTO_LEN : positive := AAD_BYTES + PT_BYTES;

    type byte_arr_t is array(natural range <>) of std_logic_vector(7 downto 0);

    -- Deterministic reference byte pattern for absolute stream index i.
    function pattern_byte(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((i*7 + 13) mod 256, 8));
    end function;

    -- Clock / reset
    signal i_clk  : std_logic := '0';
    signal i_rstn : std_logic := '0';

    -- AXIS slave (driven by TB master)
    signal s_axis_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal s_axis_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0) := (others => '0');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tready : std_logic;

    -- AXIS master: bypass (TB is slave)
    signal m_bypass_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal m_bypass_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal m_bypass_tvalid : std_logic;
    signal m_bypass_tlast  : std_logic;
    signal m_bypass_tready : std_logic := '0';

    -- AXIS master: crypto (TB is slave)
    signal m_crypto_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal m_crypto_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal m_crypto_tvalid : std_logic;
    signal m_crypto_tlast  : std_logic;
    signal m_crypto_tready : std_logic := '0';

    -- Completion / verdict
    signal bypass_done : boolean := false;
    signal crypto_done : boolean := false;
    signal bypass_pass : boolean := true;
    signal crypto_pass : boolean := true;

begin

    ----------------------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------------------
    u_dut : entity work.SPLIT_demux
        generic map (
            DATA_WIDTH   => DATA_WIDTH,
            BYPASS_BYTES => BYPASS_BYTES,
            AAD_BYTES    => AAD_BYTES
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tready => s_axis_tready,
            s_axis_tkeep  => s_axis_tkeep,

            m_bypass_axis_tdata  => m_bypass_tdata,
            m_bypass_axis_tvalid => m_bypass_tvalid,
            m_bypass_axis_tlast  => m_bypass_tlast,
            m_bypass_axis_tready => m_bypass_tready,
            m_bypass_axis_tkeep  => m_bypass_tkeep,

            m_crypto_axis_tdata  => m_crypto_tdata,
            m_crypto_axis_tvalid => m_crypto_tvalid,
            m_crypto_axis_tlast  => m_crypto_tlast,
            m_crypto_axis_tready => m_crypto_tready,
            m_crypto_axis_tkeep  => m_crypto_tkeep
        );

    ----------------------------------------------------------------------------
    -- Clock / reset
    ----------------------------------------------------------------------------
    i_clk  <= not i_clk after 5 ns;   -- 100 MHz
    i_rstn <= '0', '1' after 33 ns;

    ----------------------------------------------------------------------------
    -- AXIS master: send c_IN_BEATS beats of the reference pattern.
    ----------------------------------------------------------------------------
    p_MASTER : process
        variable v_s1   : positive := SEED1;
        variable v_s2   : positive := SEED2;
        variable v_r    : real;
        variable v_idx  : natural;
        variable v_data : std_logic_vector(DATA_WIDTH-1 downto 0);
        variable v_keep : std_logic_vector(c_BUS_BYTES-1 downto 0);
    begin
        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';
        wait until i_rstn = '1';
        wait until rising_edge(i_clk);

        for n in 0 to c_IN_BEATS-1 loop
            -- assemble beat n
            v_data := (others => '0');
            v_keep := (others => '0');
            for lane in 0 to c_BUS_BYTES-1 loop
                v_idx := n*c_BUS_BYTES + lane;
                if v_idx < c_TOTAL then
                    v_data(8*lane+7 downto 8*lane) := pattern_byte(v_idx);
                    v_keep(lane) := '1';
                end if;
            end loop;

            -- optional idle bubbles before presenting the beat
            loop
                uniform(v_s1, v_s2, v_r);
                exit when v_r*100.0 < real(P_VALID);
                s_axis_tvalid <= '0';
                wait until rising_edge(i_clk);
            end loop;

            s_axis_tdata  <= v_data;
            s_axis_tkeep  <= v_keep;
            s_axis_tvalid <= '1';
            if n = c_IN_BEATS-1 then s_axis_tlast <= '1'; else s_axis_tlast <= '0'; end if;

            -- hold until handshake
            loop
                wait until rising_edge(i_clk);
                exit when s_axis_tready = '1';
            end loop;
        end loop;

        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- AXIS slave: bypass. Collect bytes, check against bytes[0..BYPASS-1].
    ----------------------------------------------------------------------------
    p_BYPASS_SLAVE : process
        variable v_s1  : positive := SEED1 + 3;
        variable v_s2  : positive := SEED2 + 11;
        variable v_r   : real;
        variable v_rdy : std_logic;
        variable v_col : byte_arr_t(0 to BYPASS_BYTES + 4*c_BUS_BYTES - 1);
        variable v_cnt : natural := 0;
        variable v_tl  : natural := 0;
        variable v_ok  : boolean := true;
    begin
        m_bypass_tready <= '0';
        wait until i_rstn = '1';

        loop
            uniform(v_s1, v_s2, v_r);
            if v_r*100.0 < real(P_READY) then v_rdy := '1'; else v_rdy := '0'; end if;
            m_bypass_tready <= v_rdy;
            wait until rising_edge(i_clk);

            if m_bypass_tvalid = '1' and v_rdy = '1' then
                for lane in 0 to c_BUS_BYTES-1 loop
                    if m_bypass_tkeep(lane) = '1' then
                        if v_cnt <= v_col'high then
                            v_col(v_cnt) := m_bypass_tdata(8*lane+7 downto 8*lane);
                        end if;
                        v_cnt := v_cnt + 1;
                    end if;
                end loop;
                if m_bypass_tlast = '1' then
                    v_tl := v_tl + 1;
                    exit;
                end if;
            end if;
        end loop;

        m_bypass_tready <= '0';

        -- checks
        if v_cnt /= BYPASS_BYTES then
            report "BYPASS byte-count mismatch: got " & integer'image(v_cnt) &
                   " expected " & integer'image(BYPASS_BYTES) severity error;
            v_ok := false;
        else
            for i in 0 to BYPASS_BYTES-1 loop
                if v_col(i) /= pattern_byte(i) then
                    report "BYPASS data mismatch at byte " & integer'image(i) severity error;
                    v_ok := false;
                end if;
            end loop;
        end if;
        if v_tl /= 1 then
            report "BYPASS TLAST count = " & integer'image(v_tl) & " (expected 1)" severity error;
            v_ok := false;
        end if;

        bypass_pass <= v_ok;
        bypass_done <= true;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- AXIS slave: crypto. Collect bytes, check against bytes[BYPASS..end].
    ----------------------------------------------------------------------------
    p_CRYPTO_SLAVE : process
        variable v_s1  : positive := SEED1 + 5;
        variable v_s2  : positive := SEED2 + 17;
        variable v_r   : real;
        variable v_rdy : std_logic;
        variable v_col : byte_arr_t(0 to c_CRYPTO_LEN + 4*c_BUS_BYTES - 1);
        variable v_cnt : natural := 0;
        variable v_tl  : natural := 0;
        variable v_ok  : boolean := true;
    begin
        m_crypto_tready <= '0';
        wait until i_rstn = '1';

        loop
            uniform(v_s1, v_s2, v_r);
            if v_r*100.0 < real(P_READY) then v_rdy := '1'; else v_rdy := '0'; end if;
            m_crypto_tready <= v_rdy;
            wait until rising_edge(i_clk);

            if m_crypto_tvalid = '1' and v_rdy = '1' then
                if DEBUG /= 0 then
                    report "CRYPTO beat keep=" & integer'image(to_integer(unsigned(m_crypto_tkeep))) &
                           " nbytes=" & integer'image(to_integer(unsigned(m_crypto_tkeep(0 downto 0)))) &
                           " tlast=" & std_logic'image(m_crypto_tlast) &
                           " tdata=" & to_hstring(m_crypto_tdata);
                end if;
                for lane in 0 to c_BUS_BYTES-1 loop
                    if m_crypto_tkeep(lane) = '1' then
                        if v_cnt <= v_col'high then
                            v_col(v_cnt) := m_crypto_tdata(8*lane+7 downto 8*lane);
                        end if;
                        v_cnt := v_cnt + 1;
                    end if;
                end loop;
                if m_crypto_tlast = '1' then
                    v_tl := v_tl + 1;
                    exit;
                end if;
            end if;
        end loop;

        m_crypto_tready <= '0';

        -- checks
        if v_cnt /= c_CRYPTO_LEN then
            report "CRYPTO byte-count mismatch: got " & integer'image(v_cnt) &
                   " expected " & integer'image(c_CRYPTO_LEN) severity error;
            v_ok := false;
        else
            for j in 0 to c_CRYPTO_LEN-1 loop
                if v_col(j) /= pattern_byte(BYPASS_BYTES + j) then
                    report "CRYPTO data mismatch at byte " & integer'image(j) severity error;
                    v_ok := false;
                end if;
            end loop;
        end if;
        if v_tl /= 1 then
            report "CRYPTO TLAST count = " & integer'image(v_tl) & " (expected 1)" severity error;
            v_ok := false;
        end if;

        crypto_pass <= v_ok;
        crypto_done <= true;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Verdict
    ----------------------------------------------------------------------------
    p_CHECK : process
    begin
        wait until bypass_done and crypto_done;
        report "CONFIG  BYPASS=" & integer'image(BYPASS_BYTES) &
               " AAD=" & integer'image(AAD_BYTES) &
               " PT=" & integer'image(PT_BYTES) &
               " P_VALID=" & integer'image(P_VALID) &
               " P_READY=" & integer'image(P_READY);
        if bypass_pass and crypto_pass then
            report "RESULT: PASS";
        else
            report "RESULT: FAIL" severity error;
        end if;
        finish;
    end process;

    ----------------------------------------------------------------------------
    -- Global timeout guard (deadlock -> FAIL)
    ----------------------------------------------------------------------------
    p_TIMEOUT : process
    begin
        wait for 500 us;
        report "RESULT: FAIL (timeout - possible deadlock)" severity error;
        finish;
    end process;

end architecture;
