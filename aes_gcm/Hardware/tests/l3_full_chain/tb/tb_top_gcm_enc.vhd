----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_top_gcm_enc
-- Module Name   : tb_top_gcm_enc - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Streams bypass || AAD || PT through the 5-core encryption chain and
--                 checks the output packet: the bypass segment must come back untouched,
--                 the AAD echoed, and CT || ICV appended. Packet geometry and the
--                 TVALID / TREADY duty cycles are generics, so the runner can sweep
--                 back-pressure.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;

entity tb_top_gcm_enc is
    generic (
        DATA_WIDTH   : positive := 128;
        BYPASS_BYTES : positive := 50;
        AAD_BYTES    : positive := 20;
        PT_BYTES     : positive := 40;
        P_VALID      : integer  := 100;
        P_READY      : integer  := 100;
        SEED1        : integer  := 1;
        SEED2        : integer  := 7;
        DEBUG        : integer  := 0
    );
end entity;

architecture sim of tb_top_gcm_enc is

    constant c_BUS_BYTES : positive := DATA_WIDTH / 8;
    constant c_ICV_BYTES : positive := 16;
    constant c_IN_TOTAL  : positive := BYPASS_BYTES + AAD_BYTES + PT_BYTES;
    constant c_IN_BEATS  : positive := (c_IN_TOTAL + c_BUS_BYTES - 1) / c_BUS_BYTES;
    constant c_OUT_TOTAL : positive := c_IN_TOTAL + c_ICV_BYTES;

    type byte_arr_t is array(natural range <>) of std_logic_vector(7 downto 0);

    function pattern_byte(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((i*7 + 13) mod 256, 8));
    end function;

    signal i_clk  : std_logic := '0';
    signal i_rstn : std_logic := '0';

    signal i_key       : std_logic_vector(255 downto 0) := (others => '0');
    signal i_key_valid : std_logic := '0';
    signal i_nonce        : std_logic_vector(95 downto 0)  := (others => '0');
    signal i_nonce_valid  : std_logic := '0';

    signal s_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0)  := (others => '0');
    signal s_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0) := (others => '0');
    signal s_tvalid : std_logic := '0';
    signal s_tlast  : std_logic := '0';
    signal s_tready : std_logic;

    signal m_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal m_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal m_tvalid : std_logic;
    signal m_tlast  : std_logic;
    signal m_tready : std_logic := '0';

    signal o_in_proc : std_logic;
    signal o_txenc   : std_logic_vector(31 downto 0);

    signal out_done : boolean := false;
    signal out_pass : boolean := true;

begin

    u_dut : entity work.top_gcm_enc
        generic map (
            DATA_WIDTH   => DATA_WIDTH,
            BYPASS_BYTES => BYPASS_BYTES,
            AAD_BYTES    => AAD_BYTES
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            i_key       => i_key,
            i_key_valid => i_key_valid,
            i_nonce        => i_nonce,
            i_nonce_valid  => i_nonce_valid,

            s_axis_tdata  => s_tdata,
            s_axis_tkeep  => s_tkeep,
            s_axis_tvalid => s_tvalid,
            s_axis_tlast  => s_tlast,
            s_axis_tready => s_tready,

            m_axis_tdata  => m_tdata,
            m_axis_tkeep  => m_tkeep,
            m_axis_tvalid => m_tvalid,
            m_axis_tlast  => m_tlast,
            m_axis_tready => m_tready,

            o_ENC_in_proc => o_in_proc,
            o_TxENC       => o_txenc
        );

    i_clk  <= not i_clk after 5 ns;
    i_rstn <= '0', '1' after 33 ns;

    ----------------------------------------------------------------------------
    -- Key / IV config, then stream the plain packet
    ----------------------------------------------------------------------------
    p_MASTER : process
        variable v_s1   : positive := SEED1;
        variable v_s2   : positive := SEED2;
        variable v_r    : real;
        variable v_idx  : natural;
        variable v_data : std_logic_vector(DATA_WIDTH-1 downto 0);
        variable v_keep : std_logic_vector(c_BUS_BYTES-1 downto 0);
    begin
        s_tvalid <= '0';
        s_tlast  <= '0';
        wait until i_rstn = '1';
        wait until rising_edge(i_clk);

        -- key = 0x000102..0F in the low 128 bits, IV = 0xA0A1..AF
        for b in 0 to 15 loop
            i_key(8*b+7 downto 8*b) <= std_logic_vector(to_unsigned(b, 8));
        end loop;
        for b in 0 to 11 loop
            i_nonce(8*b+7 downto 8*b) <= std_logic_vector(to_unsigned(160 + b, 8));
        end loop;
        wait until rising_edge(i_clk);
        i_key_valid <= '1';
        i_nonce_valid  <= '1';
        wait until rising_edge(i_clk);
        i_key_valid <= '0';
        i_nonce_valid  <= '0';

        -- let the AES core derive H and E_k(J0)
        for k in 0 to 200 loop
            wait until rising_edge(i_clk);
        end loop;

        for n in 0 to c_IN_BEATS-1 loop
            v_data := (others => '0');
            v_keep := (others => '0');
            for lane in 0 to c_BUS_BYTES-1 loop
                v_idx := n*c_BUS_BYTES + lane;
                if v_idx < c_IN_TOTAL then
                    v_data(8*lane+7 downto 8*lane) := pattern_byte(v_idx);
                    v_keep(lane) := '1';
                end if;
            end loop;

            loop
                uniform(v_s1, v_s2, v_r);
                exit when v_r*100.0 < real(P_VALID);
                s_tvalid <= '0';
                wait until rising_edge(i_clk);
            end loop;

            s_tdata  <= v_data;
            s_tkeep  <= v_keep;
            s_tvalid <= '1';
            if n = c_IN_BEATS-1 then s_tlast <= '1'; else s_tlast <= '0'; end if;

            loop
                wait until rising_edge(i_clk);
                exit when s_tready = '1';
            end loop;
        end loop;

        s_tvalid <= '0';
        s_tlast  <= '0';
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Collect the protected packet and check it
    ----------------------------------------------------------------------------
    p_SINK : process
        variable v_s1   : positive := SEED1 + 3;
        variable v_s2   : positive := SEED2 + 11;
        variable v_r    : real;
        variable v_rdy  : std_logic;
        variable v_col  : byte_arr_t(0 to c_OUT_TOTAL + 4*c_BUS_BYTES - 1);
        variable v_cnt  : natural := 0;
        variable v_tl   : natural := 0;
        variable v_ok   : boolean := true;
        variable v_diff : natural := 0;
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

        -- 1) total length = header + AAD + CT(=PT) + ICV
        if v_cnt /= c_OUT_TOTAL then
            report "LENGTH mismatch: got " & integer'image(v_cnt) &
                   " expected " & integer'image(c_OUT_TOTAL) severity error;
            v_ok := false;
        else
            -- 2) header passes through untouched
            for i in 0 to BYPASS_BYTES-1 loop
                if v_col(i) /= pattern_byte(i) then
                    report "HEADER mismatch at byte " & integer'image(i) severity error;
                    v_ok := false;
                end if;
            end loop;
            -- 3) AAD travels in the clear
            for j in 0 to AAD_BYTES-1 loop
                if v_col(BYPASS_BYTES + j) /= pattern_byte(BYPASS_BYTES + j) then
                    report "AAD mismatch at byte " & integer'image(j) severity error;
                    v_ok := false;
                end if;
            end loop;
            -- 4) the CT region must NOT equal the PT (data really got encrypted)
            for k in 0 to PT_BYTES-1 loop
                if v_col(BYPASS_BYTES + AAD_BYTES + k) /=
                   pattern_byte(BYPASS_BYTES + AAD_BYTES + k) then
                    v_diff := v_diff + 1;
                end if;
            end loop;
            if v_diff = 0 then
                report "CT identical to PT - nothing was encrypted!" severity error;
                v_ok := false;
            else
                report "CT differs from PT in " & integer'image(v_diff) & "/" &
                       integer'image(PT_BYTES) & " bytes (encrypted)";
            end if;
        end if;

        if v_tl /= 1 then
            report "TLAST count = " & integer'image(v_tl) & " (expected 1)" severity error;
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
               " PT=" & integer'image(PT_BYTES) &
               " P_VALID=" & integer'image(P_VALID) &
               " P_READY=" & integer'image(P_READY);
        if out_pass then
            report "RESULT: PASS";
        else
            report "RESULT: FAIL" severity error;
        end if;
        finish;
    end process;

    p_TIMEOUT : process
    begin
        wait for 2 ms;
        report "RESULT: FAIL (timeout - possible deadlock)" severity error;
        finish;
    end process;

end architecture;
