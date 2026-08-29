----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_reset_midpacket
-- Module Name   : tb_reset_midpacket - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Reset asserted in the middle of a packet. The core must recover
--                 cleanly and the next packet must come out bit-exact against the
--                 published vector.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;

entity tb_reset_midpacket is
    generic (
        G_WRAPPER_KIND : string  := "MULTICORE";
        G_NUM_CORES    : integer := 4
    );
end entity;

architecture sim of tb_reset_midpacket is

    constant c_CLK_PERIOD : time := 5 ns;

    type t_blk_arr is array (natural range <>) of std_logic_vector(127 downto 0);

    -- NIST AES-128-GCM Test Case 3
    constant c_KEY : std_logic_vector(127 downto 0) :=
        x"feffe9928665731c6d6a8f9467308308";
    constant c_IV  : std_logic_vector(95 downto 0) := x"cafebabefacedbaddecaf888";
    constant c_PT : t_blk_arr(0 to 3) := (
        x"d9313225f88406e5a55909c5aff5269a",
        x"86a7a9531534f7da2e4c303d8a318a72",
        x"1c3c0c95956809532fcf0e2449a6b525",
        x"b16aedf5aa0de657ba637b391aafd255");
    constant c_CT : t_blk_arr(0 to 3) := (
        x"42831ec2217774244b7221b784d0d49c",
        x"e3aa212f2c02a4e035c17e2329aca12e",
        x"21d514b25466931c7d8f6a5aac84aa05",
        x"1ba30b396a0aac973d58e091473f5985");
    constant c_TAG : std_logic_vector(127 downto 0) :=
        x"4d5c2af327cd64a62cf35abd2ba6fab4";

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

    signal i_key         : std_logic_vector(127 downto 0) := (others => '0');
    signal i_key_valid   : std_logic := '0';
    signal i_nonce       : std_logic_vector(95 downto 0)  := (others => '0');
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
            AES_BITS => 128, ROUND_STYLE => "LUT",
            WRAPPER_KIND => G_WRAPPER_KIND, NUM_CORES => G_NUM_CORES,
            AAD_BEATS => 0, DATA_WIDTH => 128)
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
                sv_out(sv_cnt mod 16) := m_axis_tdata;
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

        procedure send_beat(constant d : in std_logic_vector(127 downto 0);
                            constant last : in std_logic) is
        begin
            s_axis_tdata  <= d;
            s_axis_tlast  <= last;
            s_axis_tvalid <= '1';
            wait until rising_edge(clk) and s_axis_tready = '1';
            s_axis_tvalid <= '0';
            s_axis_tlast  <= '0';
        end procedure;

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
        report "==== tb_reset_midpacket (" & G_WRAPPER_KIND & ") ====";

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- Phase 1: start a packet with an unrelated key/nonce, then yank reset
        -- in the middle of its body.
        ------------------------------------------------------------------------
        i_key       <= x"ffeeddccbbaa99887766554433221100";
        i_key_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0';
        for i in 1 to 4 loop wait until rising_edge(clk); end loop;

        i_nonce       <= x"0102030405060708090a0b0c";
        i_nonce_valid <= '1';
        wait until rising_edge(clk);
        i_nonce_valid <= '0';

        for i in 1 to 2000 loop
            wait until rising_edge(clk);
            exit when s_axis_tready = '1';
        end loop;
        assert s_axis_tready = '1' report "phase 1 never opened" severity failure;

        -- 3 of 8 beats, then reset mid-body
        send_beat(x"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", '0');
        send_beat(x"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", '0');
        send_beat(x"cccccccccccccccccccccccccccccccc", '0');

        report "asserting reset mid-packet";
        s_axis_tvalid <= '0';
        s_axis_tlast  <= '0';
        rstn          <= '0';
        for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        rstn <= '1';

        ------------------------------------------------------------------------
        -- Post-reset silence: nothing may come out before re-configuration
        ------------------------------------------------------------------------
        sv_cnt  := 0;
        sv_done := false;
        for i in 1 to 300 loop wait until rising_edge(clk); end loop;
        assert sv_cnt = 0
            report "FAIL: " & integer'image(sv_cnt)
                 & " beats emitted after reset without configuration"
            severity failure;
        report "post-reset silence PASS";

        ------------------------------------------------------------------------
        -- Phase 2: NIST Test Case 3 -- must be bit-exact despite the aborted
        -- packet before the reset.
        ------------------------------------------------------------------------
        i_key       <= c_KEY;
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
        assert s_axis_tready = '1' report "phase 2 never opened" severity failure;

        for b in 0 to 3 loop
            if b = 3 then
                send_beat(byte_reverse(c_PT(b)), '1');
            else
                send_beat(byte_reverse(c_PT(b)), '0');
            end if;
        end loop;

        for i in 1 to 3000 loop
            wait until rising_edge(clk);
            exit when sv_done;
        end loop;
        assert sv_done report "phase 2 output never completed" severity failure;
        assert sv_cnt = 5
            report "phase 2: got " & integer'image(sv_cnt)
                 & " beats, expected 5" severity failure;

        for b in 0 to 3 loop
            check_beat(b, byte_reverse(c_CT(b)), "CT");
        end loop;
        check_beat(4, byte_reverse(c_TAG), "TAG");

        if v_fail = 0 then
            report "==== tb_reset_midpacket (" & G_WRAPPER_KIND
                 & "): ALL PASS (clean recovery, KAT bit-exact) ====";
        else
            report "==== tb_reset_midpacket FAIL: " & integer'image(v_fail)
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
