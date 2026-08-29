----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_gcm_kat
-- Module Name   : tb_gcm_kat - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Known-answer test for the whole 5-core encryption chain.
--
--                 NIST SP 800-38D / McGrew-Viega test case 4:
--                   K   = feffe9928665731c6d6a8f9467308308
--                   IV  = cafebabefacedbaddecaf888          (96-bit nonce)
--                   A   = 20 bytes  (partial - not a multiple of the bus)
--                   P   = 60 bytes  (partial)
--                   T   = 5bc94fbc3221a5db94fae95ae7121a47
--
--                 Both partial-block paths are therefore exercised in one
--                 vector. The bypass segment is a 16-byte header that must come
--                 back untouched; the CT beats and the ICV are compared
--                 bit-exact against the published vector.
--
--                 KEY_REV / IV_REV select the byte order handed to the core, so
--                 a byte-order break can be diagnosed rather than merely
--                 observed. The passing configuration is KEY_REV = IV_REV = 0.
--
--                 This is the only class of test that proves standard
--                 compliance: a wrong-but-consistent byte order round-trips
--                 perfectly, so the ENC and LOOPBACK sweeps cannot see it.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_gcm_kat is
    generic (
        KEY_REV : integer := 0;
        IV_REV  : integer := 0;
        VERBOSE : integer := 1
    );
end entity;

architecture sim of tb_gcm_kat is

    constant c_DW        : positive := 128;
    constant c_BUS_BYTES : positive := 16;

    constant c_HDR_BYTES : positive := 16;
    constant c_AAD_BYTES : positive := 20;
    constant c_PT_BYTES  : positive := 60;
    constant c_ICV_BYTES : positive := 16;

    constant c_IN_TOTAL  : positive := c_HDR_BYTES + c_AAD_BYTES + c_PT_BYTES;   -- 96
    constant c_OUT_TOTAL : positive := c_IN_TOTAL + c_ICV_BYTES;                 -- 112
    constant c_IN_BEATS  : positive := (c_IN_TOTAL + c_BUS_BYTES - 1) / c_BUS_BYTES;

    -- ---- the vector, written MSB-first exactly as in the spec ----------------
    constant c_KEY : std_logic_vector(127 downto 0) := x"feffe9928665731c6d6a8f9467308308";
    constant c_NONCE : std_logic_vector(95 downto 0) := x"cafebabefacedbaddecaf888";
    constant c_AAD : std_logic_vector(159 downto 0) := x"feedfacedeadbeeffeedfacedeadbeefabaddad2";
    constant c_PT  : std_logic_vector(479 downto 0) :=
        x"d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" &
        x"1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39";
    constant c_CT  : std_logic_vector(479 downto 0) :=
        x"42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e" &
        x"21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091";
    constant c_TAG : std_logic_vector(127 downto 0) := x"5bc94fbc3221a5db94fae95ae7121a47";

    type byte_arr_t is array(natural range <>) of std_logic_vector(7 downto 0);

    -- byte i of a spec-order (MSB-first) vector
    function byte_of(v : std_logic_vector; i : natural) return std_logic_vector is
    begin
        return v(v'high - 8*i downto v'high - 8*i - 7);
    end function;

    -- spec-order vector -> byte-reversed (byte 0 lands in the LSB)
    function lsb_first(v : std_logic_vector) return std_logic_vector is
        variable r : std_logic_vector(v'length-1 downto 0);
    begin
        for i in 0 to v'length/8 - 1 loop
            r(8*i+7 downto 8*i) := byte_of(v, i);
        end loop;
        return r;
    end function;

    -- byte i of the plain input packet: dummy header, then AAD, then PT
    function in_byte(i : natural) return std_logic_vector is
    begin
        if i < c_HDR_BYTES then
            return std_logic_vector(to_unsigned((i*7 + 13) mod 256, 8));
        elsif i < c_HDR_BYTES + c_AAD_BYTES then
            return byte_of(c_AAD, i - c_HDR_BYTES);
        else
            return byte_of(c_PT, i - c_HDR_BYTES - c_AAD_BYTES);
        end if;
    end function;

    -- byte i of the expected protected packet
    function exp_byte(i : natural) return std_logic_vector is
    begin
        if i < c_HDR_BYTES + c_AAD_BYTES then
            return in_byte(i);                                   -- header + AAD in the clear
        elsif i < c_HDR_BYTES + c_AAD_BYTES + c_PT_BYTES then
            return byte_of(c_CT, i - c_HDR_BYTES - c_AAD_BYTES); -- ciphertext
        else
            return byte_of(c_TAG, i - c_HDR_BYTES - c_AAD_BYTES - c_PT_BYTES);  -- tag
        end if;
    end function;

    signal i_clk  : std_logic := '0';
    signal i_rstn : std_logic := '0';

    signal i_key       : std_logic_vector(255 downto 0) := (others => '0');
    signal i_key_valid : std_logic := '0';
    signal i_nonce        : std_logic_vector(95 downto 0)  := (others => '0');
    signal i_nonce_valid  : std_logic := '0';

    signal s_tdata  : std_logic_vector(c_DW-1 downto 0)        := (others => '0');
    signal s_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0) := (others => '0');
    signal s_tvalid : std_logic := '0';
    signal s_tlast  : std_logic := '0';
    signal s_tready : std_logic;

    signal m_tdata  : std_logic_vector(c_DW-1 downto 0);
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
            DATA_WIDTH   => c_DW,
            BYPASS_BYTES => c_HDR_BYTES,
            AAD_BYTES    => c_AAD_BYTES
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
    -- Key / IV, then the vector packet
    ----------------------------------------------------------------------------
    p_MASTER : process
        variable v_data : std_logic_vector(c_DW-1 downto 0);
        variable v_keep : std_logic_vector(c_BUS_BYTES-1 downto 0);
        variable v_idx  : natural;
    begin
        wait until i_rstn = '1';
        wait until rising_edge(i_clk);

        if KEY_REV = 0 then
            i_key(127 downto 0) <= c_KEY;
        else
            i_key(127 downto 0) <= lsb_first(c_KEY);
        end if;
        if IV_REV = 0 then
            i_nonce <= c_NONCE;
        else
            i_nonce <= lsb_first(c_NONCE);
        end if;

        wait until rising_edge(i_clk);
        i_key_valid <= '1';
        i_nonce_valid  <= '1';
        wait until rising_edge(i_clk);
        i_key_valid <= '0';
        i_nonce_valid  <= '0';

        for k in 0 to 200 loop
            wait until rising_edge(i_clk);
        end loop;

        for n in 0 to c_IN_BEATS-1 loop
            v_data := (others => '0');
            v_keep := (others => '0');
            for lane in 0 to c_BUS_BYTES-1 loop
                v_idx := n*c_BUS_BYTES + lane;
                if v_idx < c_IN_TOTAL then
                    v_data(8*lane+7 downto 8*lane) := in_byte(v_idx);
                    v_keep(lane) := '1';
                end if;
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
    -- Compare against the vector
    ----------------------------------------------------------------------------
    p_SINK : process
        variable v_col     : byte_arr_t(0 to c_OUT_TOTAL + 4*c_BUS_BYTES - 1);
        variable v_cnt     : natural := 0;
        variable v_ok      : boolean := true;
        variable v_ct_bad  : natural := 0;
        variable v_tag_bad : natural := 0;
        variable v_line    : string(1 to 32);
    begin
        m_tready <= '1';
        wait until i_rstn = '1';

        loop
            wait until rising_edge(i_clk);
            if m_tvalid = '1' then
                for lane in 0 to c_BUS_BYTES-1 loop
                    if m_tkeep(lane) = '1' then
                        if v_cnt <= v_col'high then
                            v_col(v_cnt) := m_tdata(8*lane+7 downto 8*lane);
                        end if;
                        v_cnt := v_cnt + 1;
                    end if;
                end loop;
                exit when m_tlast = '1';
            end if;
        end loop;
        m_tready <= '0';

        if v_cnt /= c_OUT_TOTAL then
            report "LENGTH mismatch: got " & integer'image(v_cnt) &
                   " expected " & integer'image(c_OUT_TOTAL) severity error;
            v_ok := false;
        else
            for k in 0 to c_PT_BYTES-1 loop
                if v_col(c_HDR_BYTES + c_AAD_BYTES + k) /= byte_of(c_CT, k) then
                    v_ct_bad := v_ct_bad + 1;
                end if;
            end loop;
            for k in 0 to c_ICV_BYTES-1 loop
                if v_col(c_HDR_BYTES + c_AAD_BYTES + c_PT_BYTES + k) /= byte_of(c_TAG, k) then
                    v_tag_bad := v_tag_bad + 1;
                end if;
            end loop;

            if VERBOSE /= 0 then
                for k in 0 to 15 loop
                    v_line(2*k+1 to 2*k+2) := to_hstring(v_col(c_HDR_BYTES + c_AAD_BYTES + k));
                end loop;
                report "CT[0:15]  got=" & v_line;
                for k in 0 to 15 loop
                    v_line(2*k+1 to 2*k+2) := to_hstring(byte_of(c_CT, k));
                end loop;
                report "CT[0:15]  exp=" & v_line;
                for k in 0 to 15 loop
                    v_line(2*k+1 to 2*k+2) :=
                        to_hstring(v_col(c_HDR_BYTES + c_AAD_BYTES + c_PT_BYTES + k));
                end loop;
                report "TAG       got=" & v_line;
                for k in 0 to 15 loop
                    v_line(2*k+1 to 2*k+2) := to_hstring(byte_of(c_TAG, k));
                end loop;
                report "TAG       exp=" & v_line;
            end if;

            if v_ct_bad /= 0 then
                report "CT mismatch in " & integer'image(v_ct_bad) & "/" &
                       integer'image(c_PT_BYTES) & " bytes" severity error;
                v_ok := false;
            else
                report "CT matches the vector (60/60 bytes)";
            end if;
            if v_tag_bad /= 0 then
                report "TAG mismatch in " & integer'image(v_tag_bad) & "/16 bytes" severity error;
                v_ok := false;
            else
                report "TAG matches the vector";
            end if;
        end if;

        out_pass <= v_ok;
        out_done <= true;
        wait;
    end process;

    p_CHECK : process
    begin
        wait until out_done;
        report "KAT  KEY_REV=" & integer'image(KEY_REV) &
               "  IV_REV=" & integer'image(IV_REV);
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
        report "RESULT: FAIL (timeout)" severity error;
        finish;
    end process;

end architecture;
