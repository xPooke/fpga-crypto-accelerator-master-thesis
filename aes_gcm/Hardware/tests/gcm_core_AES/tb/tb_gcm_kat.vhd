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
-- Description   : NIST SP 800-38D conformance for the GCM encryptor: AES-128 with and
--                 without AAD, and AES-256. Every CT beat and the ICV are compared
--                 bit-exact against the published vector.
--
--                 The vectors are written in GCM block order and reversed into AXIS
--                 order at the DUT boundary - the core is an AXIS IP, so byte 0 of the
--                 stream travels in the LSB lane.
--
--                 This is the ONLY class of test that proves standard compliance: a
--                 wrong-but-consistent byte order round-trips perfectly, so no loopback
--                 can see it.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;

entity tb_gcm_kat is
    generic (
        G_MULT_CYCLES  : integer := 2;   -- GHASH multiply timing: 1 or 2 cycles
        G_WRAPPER_KIND : string  := "MULTICORE";
        G_NUM_CORES    : integer := 4;
        G_AES_BITS     : integer := 128;
        G_AAD_BEATS    : natural := 0
    );
end entity;

architecture sim of tb_gcm_kat is

    constant c_CLK_PERIOD : time := 5 ns;

    type t_blk_arr is array (natural range <>) of std_logic_vector(127 downto 0);

    ----------------------------------------------------------------------------
    -- Vector 1: NIST SP 800-38D AES-128-GCM Test Case 3 (AAD = 0)
    ----------------------------------------------------------------------------
    constant c_V1_KEY : std_logic_vector(127 downto 0) :=
        x"feffe9928665731c6d6a8f9467308308";
    constant c_V1_PT : t_blk_arr(0 to 3) := (
        x"d9313225f88406e5a55909c5aff5269a",
        x"86a7a9531534f7da2e4c303d8a318a72",
        x"1c3c0c95956809532fcf0e2449a6b525",
        x"b16aedf5aa0de657ba637b391aafd255");
    constant c_V1_CT : t_blk_arr(0 to 3) := (
        x"42831ec2217774244b7221b784d0d49c",
        x"e3aa212f2c02a4e035c17e2329aca12e",
        x"21d514b25466931c7d8f6a5aac84aa05",
        x"1ba30b396a0aac973d58e091473f5985");
    constant c_V1_TAG : std_logic_vector(127 downto 0) :=
        x"4d5c2af327cd64a62cf35abd2ba6fab4";

    ----------------------------------------------------------------------------
    -- Vector 2: AES-128-GCM with 32-byte AAD (all 0xff), PT = bytes 0x00..0x3f
    ----------------------------------------------------------------------------
    constant c_V2_KEY : std_logic_vector(127 downto 0) :=
        x"000102030405060708090a0b0c0d0e0f";
    constant c_V2_PT : t_blk_arr(0 to 3) := (
        x"000102030405060708090a0b0c0d0e0f",
        x"101112131415161718191a1b1c1d1e1f",
        x"202122232425262728292a2b2c2d2e2f",
        x"303132333435363738393a3b3c3d3e3f");
    constant c_V2_CT : t_blk_arr(0 to 3) := (
        x"8978c5b581f28706a219c38351f7aee8",
        x"961a2a374ffea6b229f00c606a3af3ce",
        x"ba08bb23d6313b5be5669a17af89e514",
        x"fcdf3b6c4509e254d89b73a01cd4bfda");
    constant c_V2_TAG : std_logic_vector(127 downto 0) :=
        x"0e2321dc8039f4ebac79154a004edd09";

    ----------------------------------------------------------------------------
    -- Vector 3: AES-256-GCM, AAD = 0, PT = bytes 0x00..0x3f
    ----------------------------------------------------------------------------
    constant c_V3_KEY : std_logic_vector(255 downto 0) :=
        x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    constant c_V3_CT : t_blk_arr(0 to 3) := (
        x"8aa2a225ae7f491c4e0257d677108730",
        x"1d31d242cb0c7c6356c61e6aa2947be0",
        x"8d71e365e5f16f450e7202431eae0e4a",
        x"69659b6297bfbee71bab4b0782d9897d");
    constant c_V3_TAG : std_logic_vector(127 downto 0) :=
        x"9372ed9899a2ea9125e4c483c5eceafd";

    -- common IV (96-bit nonce)
    constant c_IV : std_logic_vector(95 downto 0) := x"cafebabefacedbaddecaf888";

    -- active selections
    function sel_key return std_logic_vector is
    begin
        if G_AES_BITS = 256 then
            return c_V3_KEY;
        elsif G_AAD_BEATS = 2 then
            return c_V2_KEY;
        else
            return c_V1_KEY;
        end if;
    end function;

    function sel_pt return t_blk_arr is
    begin
        if G_AES_BITS = 256 or G_AAD_BEATS = 2 then
            return c_V2_PT;   -- V2 and V3 share the same PT
        else
            return c_V1_PT;
        end if;
    end function;

    function sel_ct return t_blk_arr is
    begin
        if G_AES_BITS = 256 then
            return c_V3_CT;
        elsif G_AAD_BEATS = 2 then
            return c_V2_CT;
        else
            return c_V1_CT;
        end if;
    end function;

    function sel_tag return std_logic_vector is
    begin
        if G_AES_BITS = 256 then
            return c_V3_TAG;
        elsif G_AAD_BEATS = 2 then
            return c_V2_TAG;
        else
            return c_V1_TAG;
        end if;
    end function;

    constant c_PT  : t_blk_arr(0 to 3) := sel_pt;
    constant c_CT  : t_blk_arr(0 to 3) := sel_ct;
    constant c_TAG : std_logic_vector(127 downto 0) := sel_tag;

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';


    ----------------------------------------------------------------------------
    -- The core is an AXIS IP: byte 0 of the stream travels in the LSB lane. The
    -- published vectors below are written in GCM block order (byte 0 at the MSB),
    -- so they are converted at the DUT boundary.
    ----------------------------------------------------------------------------
    function byte_reverse (constant v : std_logic_vector) return std_logic_vector is
        constant c_N   : natural := v'length / 8;
        variable v_out : std_logic_vector(v'length-1 downto 0);
    begin
        for i in 0 to c_N-1 loop
            v_out(8*i+7 downto 8*i) := v(8*(c_N-1-i)+7 downto 8*(c_N-1-i));
        end loop;
        return v_out;
    end function;

    signal i_key         : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '0');
    signal i_key_valid   : std_logic := '0';
    signal i_nonce       : std_logic_vector(95 downto 0) := (others => '0');
    signal i_nonce_valid : std_logic := '0';

    signal s_axis_tdata  : std_logic_vector(127 downto 0) := (others => '0');
    signal s_axis_tkeep  : std_logic_vector(15 downto 0)  := (others => '1');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tlast  : std_logic := '0';
    signal s_axis_tready : std_logic;

    signal m_axis_tdata  : std_logic_vector(127 downto 0);
    signal m_axis_tkeep  : std_logic_vector(15 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tlast  : std_logic;
    signal m_axis_tready : std_logic := '1';

    -- capture
    type t_mem is array (0 to 15) of std_logic_vector(127 downto 0);
    shared variable sv_out  : t_mem := (others => (others => '0'));
    shared variable sv_cnt  : integer := 0;
    shared variable sv_done : boolean := false;

begin

    p_CLK : process
    begin
        clk <= '0';
        wait for c_CLK_PERIOD / 2;
        clk <= '1';
        wait for c_CLK_PERIOD / 2;
    end process;

    u_dut : entity work.gcm_enc
        generic map (
            AES_BITS => G_AES_BITS, ROUND_STYLE => "LUT",
            WRAPPER_KIND => G_WRAPPER_KIND, NUM_CORES => G_NUM_CORES,
            AAD_BEATS => G_AAD_BEATS, DATA_WIDTH => 128,
            MULT_CYCLES => G_MULT_CYCLES)
        port map (
            i_clk => clk, i_rstn => rstn,
            i_key => i_key, i_key_valid => i_key_valid,
            i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,
            s_axis_tdata => s_axis_tdata, s_axis_tkeep => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid, s_axis_tlast => s_axis_tlast,
            s_axis_tready => s_axis_tready,
            m_axis_tdata => m_axis_tdata, m_axis_tkeep => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid, m_axis_tlast => m_axis_tlast,
            m_axis_tready => m_axis_tready);

    p_SINK : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '1' and m_axis_tvalid = '1' and m_axis_tready = '1' then
                sv_out(sv_cnt) := m_axis_tdata;
                sv_cnt := sv_cnt + 1;
                if m_axis_tlast = '1' then
                    sv_done := true;
                end if;
            end if;
        end if;
    end process;

    p_STIM : process
        variable v_fail : integer := 0;
        variable v_l    : line;

        procedure check_beat(constant idx : in integer;
                             constant exp : in std_logic_vector(127 downto 0);
                             constant tag : in string) is
        begin
            if sv_out(idx) /= exp then
                v_fail := v_fail + 1;
                write(v_l, string'("  MISMATCH ") & tag & string'(" beat "));
                write(v_l, idx);
                writeline(output, v_l);
                write(v_l, string'("    got "));
                hwrite(v_l, sv_out(idx));
                writeline(output, v_l);
                write(v_l, string'("    exp "));
                hwrite(v_l, exp);
                writeline(output, v_l);
            end if;
        end procedure;
    begin
        report "==== tb_gcm_kat (" & G_WRAPPER_KIND
             & ", AES-" & integer'image(G_AES_BITS)
             & ", AAD=" & integer'image(G_AAD_BEATS) & ") ====";

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        i_key       <= sel_key;
        i_key_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';
        for i in 1 to 4 loop wait until rising_edge(clk); end loop;

        i_nonce       <= c_IV;
        i_nonce_valid <= '1';
        wait until rising_edge(clk);
        i_nonce_valid <= '0';

        for i in 1 to 2000 loop
            wait until rising_edge(clk);
            exit when s_axis_tready = '1';
        end loop;
        assert s_axis_tready = '1' report "pipeline never opened" severity failure;

        -- AAD beats (all 0xff)
        for b in 0 to G_AAD_BEATS-1 loop
            s_axis_tdata  <= (others => '1');
            s_axis_tlast  <= '0';
            s_axis_tvalid <= '1';
            wait until rising_edge(clk) and s_axis_tready = '1';
            s_axis_tvalid <= '0';
        end loop;

        -- 4 PT blocks
        for b in 0 to 3 loop
            s_axis_tdata  <= byte_reverse(c_PT(b));
            s_axis_tlast  <= '1' when b = 3 else '0';
            s_axis_tvalid <= '1';
            wait until rising_edge(clk) and s_axis_tready = '1';
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';
        end loop;

        for i in 1 to 3000 loop
            wait until rising_edge(clk);
            exit when sv_done;
        end loop;
        assert sv_done report "output never completed" severity failure;

        assert sv_cnt = G_AAD_BEATS + 5
            report "got " & integer'image(sv_cnt) & " beats, expected "
                 & integer'image(G_AAD_BEATS + 5) severity failure;

        -- AAD passthrough
        for b in 0 to G_AAD_BEATS-1 loop
            check_beat(b, (127 downto 0 => '1'), "AAD");
        end loop;
        -- CT blocks
        for b in 0 to 3 loop
            check_beat(G_AAD_BEATS + b, byte_reverse(c_CT(b)), "CT");
        end loop;
        -- ICV
        check_beat(G_AAD_BEATS + 4, byte_reverse(c_TAG), "TAG");

        if v_fail = 0 then
            report "==== tb_gcm_kat PASS: CT + TAG bit-exact vs reference ====";
        else
            report "==== tb_gcm_kat FAIL: " & integer'image(v_fail)
                 & " mismatches ====" severity failure;
        end if;
        finish(0);
    end process;

    p_TIMEOUT : process
    begin
        wait for 100 us;
        report "Hard timeout" severity failure;
        finish(1);
    end process;

end architecture;
