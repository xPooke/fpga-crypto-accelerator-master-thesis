----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_dec_malformed
-- Module Name   : tb_dec_malformed - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Malformed packets into the decryptor: truncated, ICV-flipped and
--                 over-long. Authentication must REJECT every one of them, no PT may
--                 leak, and the core must not deadlock.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_dec_malformed is
    generic (
        G_WRAPPER_KIND : string  := "MULTICORE";
        G_NUM_CORES    : integer := 4;
        G_AES_BITS     : integer := 128
    );
end entity;

architecture sim of tb_dec_malformed is

    constant c_CLK_PERIOD : time    := 5 ns;
    constant c_PT_BEATS   : integer := 8;

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';

    -- ENC
    signal e_key         : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '0');
    signal e_key_valid   : std_logic := '0';
    signal e_nonce       : std_logic_vector(95 downto 0) := (others => '0');
    signal e_nonce_valid : std_logic := '0';
    signal e_s_tdata     : std_logic_vector(127 downto 0) := (others => '0');
    signal e_s_tkeep     : std_logic_vector(15 downto 0)  := (others => '1');
    signal e_s_tvalid    : std_logic := '0';
    signal e_s_tlast     : std_logic := '0';
    signal e_s_tready    : std_logic;
    signal e_m_tdata     : std_logic_vector(127 downto 0);
    signal e_m_tkeep     : std_logic_vector(15 downto 0);
    signal e_m_tvalid    : std_logic;
    signal e_m_tlast     : std_logic;
    signal e_m_tready    : std_logic := '1';

    -- DEC
    signal d_key         : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '0');
    signal d_key_valid   : std_logic := '0';
    signal d_nonce       : std_logic_vector(95 downto 0) := (others => '0');
    signal d_nonce_valid : std_logic := '0';
    signal d_s_tdata     : std_logic_vector(127 downto 0) := (others => '0');
    signal d_s_tkeep     : std_logic_vector(15 downto 0)  := (others => '1');
    signal d_s_tvalid    : std_logic := '0';
    signal d_s_tlast     : std_logic := '0';
    signal d_s_tready    : std_logic;
    signal d_m_tdata     : std_logic_vector(127 downto 0);
    signal d_m_tkeep     : std_logic_vector(15 downto 0);
    signal d_m_tvalid    : std_logic;
    signal d_m_tlast     : std_logic;
    signal d_m_tready    : std_logic := '1';

    signal d_auth_ok  : std_logic;
    signal d_dec_done : std_logic;

    -- captured ENC packet (CT beats + ICV)
    type t_mem is array (0 to 63) of std_logic_vector(127 downto 0);
    shared variable sv_enc_mem : t_mem := (others => (others => '0'));
    shared variable sv_enc_cnt : integer := 0;

    -- DEC observation (updated by p_DEC_OBS)
    shared variable sv_out_beats : integer := 0;      -- beats since arm
    shared variable sv_tlast     : boolean := false;  -- TLAST seen since arm
    shared variable sv_auth      : std_logic := 'U';  -- verdict at TLAST
    shared variable sv_pt_ok     : boolean := true;   -- PT compare since arm

begin

    p_CLK : process
    begin
        clk <= '0';
        wait for c_CLK_PERIOD / 2;
        clk <= '1';
        wait for c_CLK_PERIOD / 2;
    end process;

    u_enc : entity work.gcm_enc
        generic map (
            AES_BITS => G_AES_BITS, ROUND_STYLE => "LUT",
            WRAPPER_KIND => G_WRAPPER_KIND, NUM_CORES => G_NUM_CORES,
            AAD_BEATS => 0, DATA_WIDTH => 128)
        port map (
            i_clk => clk, i_rstn => rstn,
            i_key => e_key, i_key_valid => e_key_valid,
            i_nonce => e_nonce, i_nonce_valid => e_nonce_valid,
            s_axis_tdata => e_s_tdata, s_axis_tkeep => e_s_tkeep,
            s_axis_tvalid => e_s_tvalid, s_axis_tlast => e_s_tlast,
            s_axis_tready => e_s_tready,
            m_axis_tdata => e_m_tdata, m_axis_tkeep => e_m_tkeep,
            m_axis_tvalid => e_m_tvalid, m_axis_tlast => e_m_tlast,
            m_axis_tready => e_m_tready);

    u_dec : entity work.gcm_dec
        generic map (
            AES_BITS => G_AES_BITS, ROUND_STYLE => "LUT",
            WRAPPER_KIND => G_WRAPPER_KIND, NUM_CORES => G_NUM_CORES,
            AAD_BEATS => 0, DATA_WIDTH => 128)
        port map (
            i_clk => clk, i_rstn => rstn,
            i_key => d_key, i_key_valid => d_key_valid,
            i_nonce => d_nonce, i_nonce_valid => d_nonce_valid,
            s_axis_tdata => d_s_tdata, s_axis_tkeep => d_s_tkeep,
            s_axis_tvalid => d_s_tvalid, s_axis_tlast => d_s_tlast,
            s_axis_tready => d_s_tready,
            m_axis_tdata => d_m_tdata, m_axis_tkeep => d_m_tkeep,
            m_axis_tvalid => d_m_tvalid, m_axis_tlast => d_m_tlast,
            m_axis_tready => d_m_tready,
            o_auth_ok => d_auth_ok, o_dec_done => d_dec_done);

    -- capture the clean ENC packet
    p_ENC_SINK : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '1' and e_m_tvalid = '1' and e_m_tready = '1' then
                sv_enc_mem(sv_enc_cnt) := e_m_tdata;
                sv_enc_cnt := sv_enc_cnt + 1;
            end if;
        end if;
    end process;

    -- observe DEC output + verdict
    p_DEC_OBS : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '1' and d_m_tvalid = '1' and d_m_tready = '1' then
                if sv_out_beats < c_PT_BEATS then
                    if d_m_tdata /= std_logic_vector(
                           to_unsigned(sv_out_beats + 1, 128)) then
                        sv_pt_ok := false;
                    end if;
                end if;
                sv_out_beats := sv_out_beats + 1;
                if d_m_tlast = '1' then
                    sv_tlast := true;
                    sv_auth  := d_auth_ok;
                    assert d_dec_done = '1'
                        report "dec_done missing on TLAST" severity failure;
                end if;
            end if;
        end if;
    end process;

    p_STIM : process
        variable v_n_in : integer;

        procedure dec_iv(constant ofs : in integer) is
        begin
            d_nonce <= std_logic_vector(
                unsigned'(x"deadbeefcafebabe11220000") + ofs);
            d_nonce_valid <= '1';
            wait until rising_edge(clk);
            d_nonce_valid <= '0';
        end procedure;

        procedure dec_beat(constant d : in std_logic_vector(127 downto 0);
                           constant last : in std_logic) is
        begin
            d_s_tdata  <= d;
            d_s_tlast  <= last;
            d_s_tvalid <= '1';
            wait until rising_edge(clk) and d_s_tready = '1';
            d_s_tvalid <= '0';
            d_s_tlast  <= '0';
        end procedure;

        -- Replay sv_enc_mem into DEC with a malformation mode, then check.
        --   mode 0: clean   (n = sv_enc_cnt beats)
        --   mode 1: truncate (skip the last CT beat; TLAST on the ICV as usual
        --           -> stream is 1 beat shorter)
        --   mode 2: flip bit 0 of the ICV beat
        --   mode 3: insert a garbage beat before the ICV
        procedure replay(constant mode : in integer;
                         constant expect_auth : in std_logic;
                         constant check_pt    : in boolean;
                         constant tag : in string) is
            variable v_in : integer := 0;
            variable v_d  : std_logic_vector(127 downto 0);
        begin
            -- arm observation
            sv_out_beats := 0;
            sv_tlast     := false;
            sv_auth      := 'U';
            sv_pt_ok     := true;

            for i in 0 to sv_enc_cnt - 1 loop
                v_d := sv_enc_mem(i);
                if mode = 1 and i = sv_enc_cnt - 2 then
                    next;  -- drop the last CT beat
                end if;
                if mode = 2 and i = sv_enc_cnt - 1 then
                    v_d(0) := not v_d(0);
                end if;
                if mode = 3 and i = sv_enc_cnt - 1 then
                    dec_beat(x"badbadbadbadbadbadbadbadbadbad00", '0');
                    v_in := v_in + 1;
                end if;
                if i = sv_enc_cnt - 1 then
                    dec_beat(v_d, '1');
                else
                    dec_beat(v_d, '0');
                end if;
                v_in := v_in + 1;
            end loop;

            -- wait for the output packet + verdict
            for i in 1 to 3000 loop
                wait until rising_edge(clk);
                exit when sv_tlast;
            end loop;
            assert sv_tlast
                report tag & ": DEC never finished (deadlock)" severity failure;

            assert sv_out_beats = v_in - 1
                report tag & ": DEC emitted " & integer'image(sv_out_beats)
                     & " beats, expected " & integer'image(v_in - 1)
                severity failure;
            assert sv_auth = expect_auth
                report tag & ": auth_ok = " & std_logic'image(sv_auth)
                     & ", expected " & std_logic'image(expect_auth)
                severity failure;
            if check_pt then
                assert sv_pt_ok
                    report tag & ": recovered PT mismatch" severity failure;
            end if;
            report tag & " PASS (beats=" & integer'image(sv_out_beats)
                 & ", auth=" & std_logic'image(sv_auth) & ")";
        end procedure;

    begin
        report "==== tb_dec_malformed (" & G_WRAPPER_KIND & ") ====";

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        -- keys
        e_key <= std_logic_vector(
                     resize(unsigned'(x"0123456789abcdef0123456789abcdef"),
                            G_AES_BITS));
        d_key <= std_logic_vector(
                     resize(unsigned'(x"0123456789abcdef0123456789abcdef"),
                            G_AES_BITS));
        e_key_valid <= '1';
        d_key_valid <= '1';
        wait until rising_edge(clk);
        e_key_valid <= '0';
        d_key_valid <= '0';
        for i in 1 to 4 loop wait until rising_edge(clk); end loop;

        ------------------------------------------------------------------------
        -- Produce ONE clean packet on ENC: PT beats 1..8
        ------------------------------------------------------------------------
        e_nonce       <= std_logic_vector(
                             unsigned'(x"deadbeefcafebabe11220000"));
        e_nonce_valid <= '1';
        wait until rising_edge(clk);
        e_nonce_valid <= '0';

        for i in 1 to 2000 loop
            wait until rising_edge(clk);
            exit when e_s_tready = '1';
        end loop;
        assert e_s_tready = '1' report "ENC never opened" severity failure;

        for b in 1 to c_PT_BEATS loop
            e_s_tdata  <= std_logic_vector(to_unsigned(b, 128));
            e_s_tlast  <= '1' when b = c_PT_BEATS else '0';
            e_s_tvalid <= '1';
            wait until rising_edge(clk) and e_s_tready = '1';
            e_s_tvalid <= '0';
            e_s_tlast  <= '0';
        end loop;

        -- wait for the full ENC output (PT beats + ICV)
        for i in 1 to 2000 loop
            wait until rising_edge(clk);
            exit when sv_enc_cnt = c_PT_BEATS + 1;
        end loop;
        assert sv_enc_cnt = c_PT_BEATS + 1
            report "ENC produced " & integer'image(sv_enc_cnt)
                 & " beats, expected " & integer'image(c_PT_BEATS + 1)
            severity failure;
        report "clean ENC packet captured (" & integer'image(sv_enc_cnt)
             & " beats)";

        ------------------------------------------------------------------------
        -- Replay variants (each with a fresh DEC nonce; same nonce as ENC --
        -- the decryptor only verifies, IV reuse on replay is the point here)
        ------------------------------------------------------------------------
        dec_iv(0);  replay(0, '1', true,  "V1 clean   ");
        dec_iv(0);  replay(1, '0', false, "V2 truncate");
        dec_iv(0);  replay(2, '0', false, "V3 ICV-flip");
        dec_iv(0);  replay(3, '0', false, "V4 extended");
        dec_iv(0);  replay(0, '1', true,  "V5 recovery");

        report "==== tb_dec_malformed (" & G_WRAPPER_KIND & "): ALL PASS ====";
        finish(0);
    end process;

    p_TIMEOUT : process
    begin
        wait for 500 us;
        report "Hard timeout" severity failure;
        finish(1);
    end process;

end architecture;
