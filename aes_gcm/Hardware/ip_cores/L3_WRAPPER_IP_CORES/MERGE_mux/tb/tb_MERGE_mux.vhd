----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_MERGE_mux
-- Module Name   : tb_MERGE_mux - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Self-checking testbench for MERGE_mux. Two AXIS masters drive
--                 the two slaves:
--                   s_bypass : BYPASS_BYTES header (one contiguous burst)
--                   s_crypto : AAD || CT || ICV, each sub-segment beat-aligned
--                              on its own boundary (partial last beat), TLAST on
--                              the last ICV beat.
--                 The TB is the AXIS slave on m_axis, reconstructs the output
--                 bytes from TKEEP and checks against the reference:
--                   out = bypass[0..BYPASS-1] ++ crypto[0..AAD+CT+ICV-1]
--                 TVALID (both masters) and TREADY (sink) are randomly gated at
--                 P_VALID / P_READY percent. Prints "RESULT: PASS/FAIL".
--
-- Dependencies  : work.MERGE_mux, ieee.math_real, std.env
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

entity tb_MERGE_mux is
    generic (
        DATA_WIDTH   : positive := 128;
        BYPASS_BYTES : positive := 50;
        AAD_BYTES    : natural  := 20;
        CT_BYTES     : natural  := 40;
        ICV_BYTES    : positive := 16;
        P_VALID      : integer  := 100;  -- master TVALID assert probability [%]
        P_READY      : integer  := 100;  -- sink   TREADY assert probability [%]
        SEED1        : integer  := 1;
        SEED2        : integer  := 7;
        DEBUG        : integer  := 0
    );
end entity;

architecture sim of tb_MERGE_mux is

    constant c_BUS_BYTES     : positive := DATA_WIDTH / 8;
    constant c_CRYPTO_TOTAL  : positive := AAD_BYTES + CT_BYTES + ICV_BYTES;
    constant c_TOTAL_OUT     : positive := BYPASS_BYTES + c_CRYPTO_TOTAL;

    type byte_arr_t is array(natural range <>) of std_logic_vector(7 downto 0);
    type seg_arr_t  is array(0 to 2) of natural;
    constant c_SEG : seg_arr_t := (AAD_BYTES, CT_BYTES, ICV_BYTES);

    -- Independent byte patterns so a mis-ordering is caught.
    function pat_bypass(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((i*7 + 13) mod 256, 8));
    end function;

    function pat_crypto(j : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((j*3 + 100) mod 256, 8));
    end function;

    -- Clock / reset
    signal i_clk  : std_logic := '0';
    signal i_rstn : std_logic := '0';

    -- AXIS slave: bypass (driven by TB master)
    signal s_bypass_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0)  := (others => '0');
    signal s_bypass_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0) := (others => '0');
    signal s_bypass_tvalid : std_logic := '0';
    signal s_bypass_tlast  : std_logic := '0';
    signal s_bypass_tready : std_logic;

    -- AXIS slave: crypto (driven by TB master)
    signal s_crypto_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0)  := (others => '0');
    signal s_crypto_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0) := (others => '0');
    signal s_crypto_tvalid : std_logic := '0';
    signal s_crypto_tlast  : std_logic := '0';
    signal s_crypto_tready : std_logic;

    -- AXIS master: merged output (TB is slave)
    signal m_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal m_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal m_tvalid : std_logic;
    signal m_tlast  : std_logic;
    signal m_tready : std_logic := '0';

    -- Completion / verdict
    signal out_done : boolean := false;
    signal out_pass : boolean := true;

begin

    ----------------------------------------------------------------------------
    -- DUT
    ----------------------------------------------------------------------------
    u_dut : entity work.MERGE_mux
        generic map (
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            s_bypass_axis_tdata  => s_bypass_tdata,
            s_bypass_axis_tkeep  => s_bypass_tkeep,
            s_bypass_axis_tvalid => s_bypass_tvalid,
            s_bypass_axis_tlast  => s_bypass_tlast,
            s_bypass_axis_tready => s_bypass_tready,

            s_crypto_axis_tdata  => s_crypto_tdata,
            s_crypto_axis_tkeep  => s_crypto_tkeep,
            s_crypto_axis_tvalid => s_crypto_tvalid,
            s_crypto_axis_tlast  => s_crypto_tlast,
            s_crypto_axis_tready => s_crypto_tready,

            m_axis_tdata  => m_tdata,
            m_axis_tkeep  => m_tkeep,
            m_axis_tvalid => m_tvalid,
            m_axis_tlast  => m_tlast,
            m_axis_tready => m_tready
        );

    ----------------------------------------------------------------------------
    -- Clock / reset
    ----------------------------------------------------------------------------
    i_clk  <= not i_clk after 5 ns;   -- 100 MHz
    i_rstn <= '0', '1' after 33 ns;

    ----------------------------------------------------------------------------
    -- AXIS master: bypass header (one contiguous burst, TLAST on last beat).
    ----------------------------------------------------------------------------
    p_BYPASS_MASTER : process
        constant c_BEATS : positive := (BYPASS_BYTES + c_BUS_BYTES - 1) / c_BUS_BYTES;
        variable v_s1   : positive := SEED1;
        variable v_s2   : positive := SEED2;
        variable v_r    : real;
        variable v_idx  : natural;
        variable v_data : std_logic_vector(DATA_WIDTH-1 downto 0);
        variable v_keep : std_logic_vector(c_BUS_BYTES-1 downto 0);
    begin
        s_bypass_tvalid <= '0';
        s_bypass_tlast  <= '0';
        wait until i_rstn = '1';
        wait until rising_edge(i_clk);

        for n in 0 to c_BEATS-1 loop
            v_data := (others => '0');
            v_keep := (others => '0');
            for lane in 0 to c_BUS_BYTES-1 loop
                v_idx := n*c_BUS_BYTES + lane;
                if v_idx < BYPASS_BYTES then
                    v_data(8*lane+7 downto 8*lane) := pat_bypass(v_idx);
                    v_keep(lane) := '1';
                end if;
            end loop;

            loop
                uniform(v_s1, v_s2, v_r);
                exit when v_r*100.0 < real(P_VALID);
                s_bypass_tvalid <= '0';
                wait until rising_edge(i_clk);
            end loop;

            s_bypass_tdata  <= v_data;
            s_bypass_tkeep  <= v_keep;
            s_bypass_tvalid <= '1';
            if n = c_BEATS-1 then s_bypass_tlast <= '1'; else s_bypass_tlast <= '0'; end if;

            loop
                wait until rising_edge(i_clk);
                exit when s_bypass_tready = '1';
            end loop;
        end loop;

        s_bypass_tvalid <= '0';
        s_bypass_tlast  <= '0';
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- AXIS master: crypto = AAD || CT || ICV. Each sub-segment is beat-aligned
    -- on its own boundary (partial last beat); TLAST only on the last ICV beat.
    ----------------------------------------------------------------------------
    p_CRYPTO_MASTER : process
        variable v_s1    : positive := SEED1 + 5;
        variable v_s2    : positive := SEED2 + 17;
        variable v_r     : real;
        variable v_gj    : natural := 0;               -- global crypto byte index
        variable v_beats : natural;
        variable v_chunk : natural;
        variable v_data  : std_logic_vector(DATA_WIDTH-1 downto 0);
        variable v_keep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
        variable v_last  : std_logic;
    begin
        s_crypto_tvalid <= '0';
        s_crypto_tlast  <= '0';
        wait until i_rstn = '1';
        wait until rising_edge(i_clk);

        for seg in 0 to 2 loop
            v_beats := (c_SEG(seg) + c_BUS_BYTES - 1) / c_BUS_BYTES;
            for b in 0 to v_beats-1 loop
                -- bytes in this beat of this segment
                if c_SEG(seg) - b*c_BUS_BYTES >= c_BUS_BYTES then
                    v_chunk := c_BUS_BYTES;
                else
                    v_chunk := c_SEG(seg) - b*c_BUS_BYTES;
                end if;

                v_data := (others => '0');
                v_keep := (others => '0');
                for lane in 0 to c_BUS_BYTES-1 loop
                    if lane < v_chunk then
                        v_data(8*lane+7 downto 8*lane) := pat_crypto(v_gj + lane);
                        v_keep(lane) := '1';
                    end if;
                end loop;

                if seg = 2 and b = v_beats-1 then v_last := '1'; else v_last := '0'; end if;

                loop
                    uniform(v_s1, v_s2, v_r);
                    exit when v_r*100.0 < real(P_VALID);
                    s_crypto_tvalid <= '0';
                    wait until rising_edge(i_clk);
                end loop;

                s_crypto_tdata  <= v_data;
                s_crypto_tkeep  <= v_keep;
                s_crypto_tvalid <= '1';
                s_crypto_tlast  <= v_last;

                loop
                    wait until rising_edge(i_clk);
                    exit when s_crypto_tready = '1';
                end loop;

                v_gj := v_gj + v_chunk;
            end loop;
        end loop;

        s_crypto_tvalid <= '0';
        s_crypto_tlast  <= '0';
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- AXIS slave: merged output. Reconstruct bytes, check ordering / content.
    ----------------------------------------------------------------------------
    p_SINK : process
        variable v_s1  : positive := SEED1 + 3;
        variable v_s2  : positive := SEED2 + 11;
        variable v_r   : real;
        variable v_rdy : std_logic;
        variable v_col : byte_arr_t(0 to c_TOTAL_OUT + 4*c_BUS_BYTES - 1);
        variable v_cnt : natural := 0;
        variable v_tl  : natural := 0;
        variable v_ok  : boolean := true;
    begin
        m_tready <= '0';
        wait until i_rstn = '1';

        loop
            uniform(v_s1, v_s2, v_r);
            if v_r*100.0 < real(P_READY) then v_rdy := '1'; else v_rdy := '0'; end if;
            m_tready <= v_rdy;
            wait until rising_edge(i_clk);

            if m_tvalid = '1' and v_rdy = '1' then
                if DEBUG /= 0 then
                    report "OUT beat keep=" & integer'image(to_integer(unsigned(m_tkeep))) &
                           " tlast=" & std_logic'image(m_tlast) &
                           " tdata=" & to_hstring(m_tdata);
                end if;
                for lane in 0 to c_BUS_BYTES-1 loop
                    if m_tkeep(lane) = '1' then
                        if v_cnt <= v_col'high then
                            v_col(v_cnt) := m_tdata(8*lane+7 downto 8*lane);
                        end if;
                        v_cnt := v_cnt + 1;
                    end if;
                end loop;
                if m_tlast = '1' then
                    v_tl := v_tl + 1;
                    exit;
                end if;
            end if;
        end loop;

        m_tready <= '0';

        -- checks
        if v_cnt /= c_TOTAL_OUT then
            report "OUT byte-count mismatch: got " & integer'image(v_cnt) &
                   " expected " & integer'image(c_TOTAL_OUT) severity error;
            v_ok := false;
        else
            for i in 0 to BYPASS_BYTES-1 loop
                if v_col(i) /= pat_bypass(i) then
                    report "BYPASS data mismatch at byte " & integer'image(i) severity error;
                    v_ok := false;
                end if;
            end loop;
            for j in 0 to c_CRYPTO_TOTAL-1 loop
                if v_col(BYPASS_BYTES + j) /= pat_crypto(j) then
                    report "CRYPTO data mismatch at byte " & integer'image(j) severity error;
                    v_ok := false;
                end if;
            end loop;
        end if;
        if v_tl /= 1 then
            report "OUT TLAST count = " & integer'image(v_tl) & " (expected 1)" severity error;
            v_ok := false;
        end if;

        out_pass <= v_ok;
        out_done <= true;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Verdict
    ----------------------------------------------------------------------------
    p_CHECK : process
    begin
        wait until out_done;
        report "CONFIG  BYPASS=" & integer'image(BYPASS_BYTES) &
               " AAD=" & integer'image(AAD_BYTES) &
               " CT=" & integer'image(CT_BYTES) &
               " ICV=" & integer'image(ICV_BYTES) &
               " P_VALID=" & integer'image(P_VALID) &
               " P_READY=" & integer'image(P_READY);
        if out_pass then
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
