----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_gcm_kat_tkeep
-- Module Name   : tb_gcm_kat_tkeep - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Known-answer test for PARTIAL LAST BEATS. Drives packets whose last
--                 beat carries fewer than 16 valid bytes (marked by TKEEP), checks CT
--                 and the ICV bit-exact against the reference and that TKEEP is passed
--                 through, then replays the captured packet into the decryptor, which
--                 must authenticate and recover the PT.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;

entity tb_gcm_kat_tkeep is
    generic (
        G_WRAPPER_KIND : string  := "MULTICORE";
        G_NUM_CORES    : integer := 4
    );
end entity;

architecture sim of tb_gcm_kat_tkeep is

    constant c_CLK_PERIOD : time := 5 ns;

    ----------------------------------------------------------------------------
    -- Reference vectors, generated with PyCA cryptography (AES-128-GCM, AAD=0)
    ----------------------------------------------------------------------------
    constant c_KEY : std_logic_vector(127 downto 0) := x"000102030405060708090a0b0c0d0e0f";
    constant c_NUM_PKTS : integer := 6;
    type t_int_arr is array (0 to c_NUM_PKTS-1) of integer;
    constant c_BYTES : t_int_arr := (60, 52, 17, 4, 16, 31);
    constant c_MAX_BEATS : integer := 4;
    type t_blk_tbl is array (0 to c_NUM_PKTS-1, 0 to c_MAX_BEATS-1) of std_logic_vector(127 downto 0);
    constant c_PT : t_blk_tbl := (
        (x"000102030405060708090a0b0c0d0e0f",
         x"101112131415161718191a1b1c1d1e1f",
         x"202122232425262728292a2b2c2d2e2f",
         x"303132333435363738393a3b00000000"),
        (x"202122232425262728292a2b2c2d2e2f",
         x"303132333435363738393a3b3c3d3e3f",
         x"404142434445464748494a4b4c4d4e4f",
         x"50515253000000000000000000000000"),
        (x"404142434445464748494a4b4c4d4e4f",
         x"50000000000000000000000000000000",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000"),
        (x"60616263000000000000000000000000",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000"),
        (x"808182838485868788898a8b8c8d8e8f",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000"),
        (x"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf",
         x"b0b1b2b3b4b5b6b7b8b9babbbcbdbe00",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000")
    );
    constant c_CT : t_blk_tbl := (
        (x"25343be2ac55505cd788b8da9cf29934",
         x"f51ed6575850575c28d02f93b005ea4c",
         x"14159e6844db9a441e820241c4cf1ecc",
         x"8df9b84ea8f2c7486ec0820800000000"),
        (x"c2a94dbb0cd56f9015f8be4f16660c76",
         x"fea807b939b8245dab75d9d71825b361",
         x"2ecbad78419c4a76cb550ce86fb026d2",
         x"e572550a000000000000000000000000"),
        (x"a7eac0e07062a681b679124167cb509e",
         x"40000000000000000000000000000000",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000"),
        (x"3d770bc0000000000000000000000000",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000"),
        (x"17c49efa34f616cd6180119fa286af8b",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000"),
        (x"bd9a4408a5863a1a225bac0c6dfe617a",
         x"06eefce9fa6894783d155ef080095d00",
         x"00000000000000000000000000000000",
         x"00000000000000000000000000000000")
    );
    type t_tag_arr is array (0 to c_NUM_PKTS-1) of std_logic_vector(127 downto 0);
    constant c_TAG : t_tag_arr := (x"1790412af3f7b98d153149c761460eba",
                                   x"fd10ee100bcef8822f48fd7a36704842",
                                   x"fec9fdcb2a0545f53f2772768ac94b00",
                                   x"17102deec96ffe06116146d5dbdf5599",
                                   x"93748b54a80940ef1b33be1d4a6f0405",
                                   x"fcfacd737fbcd50ec7d965d6f6bfbb0b");
    type t_iv_arr is array (0 to c_NUM_PKTS-1) of std_logic_vector(95 downto 0);
    constant c_IVS : t_iv_arr := (x"cafebabefacedbaddecaf800",
                                  x"cafebabefacedbaddecaf801",
                                  x"cafebabefacedbaddecaf802",
                                  x"cafebabefacedbaddecaf803",
                                  x"cafebabefacedbaddecaf804",
                                  x"cafebabefacedbaddecaf805");

    ----------------------------------------------------------------------------
    -- Helpers
    ----------------------------------------------------------------------------
    -- beats in packet p (ceil(bytes/16))
    function f_beats(p : integer) return integer is
    begin
        return (c_BYTES(p) + 15) / 16;
    end function;

    -- valid bytes in the LAST beat of packet p (1..16)
    function f_tail(p : integer) return integer is
    begin
        return ((c_BYTES(p) - 1) mod 16) + 1;
    end function;

    -- TKEEP for an AXIS beat with n valid bytes: they sit in the LOW lanes,
    -- because byte 0 of the stream travels in lane 0.
    function f_keep(n : integer) return std_logic_vector is
        variable v_k : std_logic_vector(15 downto 0) := (others => '0');
    begin
        for i in 0 to n - 1 loop
            v_k(i) := '1';
        end loop;
        return v_k;
    end function;

    -- The published vectors are in GCM block order (byte 0 at the MSB); the DUT
    -- is an AXIS IP, so they are converted at its boundary.
    function byte_reverse (constant v : std_logic_vector) return std_logic_vector is
        constant c_N   : natural := v'length / 8;
        variable v_out : std_logic_vector(v'length-1 downto 0);
    begin
        for i in 0 to c_N-1 loop
            v_out(8*i+7 downto 8*i) := v(8*(c_N-1-i)+7 downto 8*(c_N-1-i));
        end loop;
        return v_out;
    end function;

    -- compare only the bytes whose keep bit is set
    function f_match(a, b : std_logic_vector(127 downto 0);
                     keep : std_logic_vector(15 downto 0)) return boolean is
    begin
        for l in 0 to 15 loop
            if keep(l) = '1' and a(8*l+7 downto 8*l) /= b(8*l+7 downto 8*l) then
                return false;
            end if;
        end loop;
        return true;
    end function;

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';

    -- ENC
    signal e_key         : std_logic_vector(127 downto 0) := (others => '0');
    signal e_key_valid   : std_logic := '0';
    signal e_nonce       : std_logic_vector(95 downto 0)  := (others => '0');
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
    signal d_key         : std_logic_vector(127 downto 0) := (others => '0');
    signal d_key_valid   : std_logic := '0';
    signal d_nonce       : std_logic_vector(95 downto 0)  := (others => '0');
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

    -- ENC capture (per packet)
    type t_mem  is array (0 to 7) of std_logic_vector(127 downto 0);
    type t_kmem is array (0 to 7) of std_logic_vector(15 downto 0);
    shared variable sv_e_mem  : t_mem;
    shared variable sv_e_keep : t_kmem;
    shared variable sv_e_cnt  : integer := 0;
    shared variable sv_e_done : boolean := false;

    -- DEC capture (per packet)
    shared variable sv_d_mem  : t_mem;
    shared variable sv_d_keep : t_kmem;
    shared variable sv_d_cnt  : integer := 0;
    shared variable sv_d_done : boolean := false;
    shared variable sv_d_auth : std_logic := 'U';

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
            AES_BITS => 128, ROUND_STYLE => "LUT",
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
            AES_BITS => 128, ROUND_STYLE => "LUT",
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

    p_E_SINK : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '1' and e_m_tvalid = '1' and e_m_tready = '1' then
                sv_e_mem(sv_e_cnt)  := e_m_tdata;
                sv_e_keep(sv_e_cnt) := e_m_tkeep;
                sv_e_cnt := sv_e_cnt + 1;
                if e_m_tlast = '1' then
                    sv_e_done := true;
                end if;
            end if;
        end if;
    end process;

    p_D_SINK : process(clk)
    begin
        if rising_edge(clk) then
            if rstn = '1' and d_m_tvalid = '1' and d_m_tready = '1' then
                sv_d_mem(sv_d_cnt)  := d_m_tdata;
                sv_d_keep(sv_d_cnt) := d_m_tkeep;
                sv_d_cnt := sv_d_cnt + 1;
                if d_m_tlast = '1' then
                    sv_d_done := true;
                    sv_d_auth := d_auth_ok;
                    assert d_dec_done = '1'
                        report "dec_done missing on TLAST" severity failure;
                end if;
            end if;
        end if;
    end process;

    p_STIM : process
        variable v_fail  : integer := 0;
        variable v_beats : integer;
        variable v_keep  : std_logic_vector(15 downto 0);
        variable v_l     : line;

        procedure note_mismatch(constant p, b : in integer;
                                constant what : in string;
                                constant got, exp : in std_logic_vector(127 downto 0)) is
        begin
            v_fail := v_fail + 1;
            write(v_l, string'("  pkt "));
            write(v_l, p);
            write(v_l, string'(" ") & what & string'(" beat "));
            write(v_l, b);
            writeline(output, v_l);
            write(v_l, string'("    got "));
            hwrite(v_l, got);
            writeline(output, v_l);
            write(v_l, string'("    exp "));
            hwrite(v_l, exp);
            writeline(output, v_l);
        end procedure;
    begin
        report "==== tb_gcm_kat_tkeep (" & G_WRAPPER_KIND & ") ====";

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        e_key <= c_KEY;  d_key <= c_KEY;
        e_key_valid <= '1';  d_key_valid <= '1';
        wait until rising_edge(clk);
        e_key_valid <= '0';  d_key_valid <= '0';
        for i in 1 to 4 loop wait until rising_edge(clk); end loop;

        for p in 0 to c_NUM_PKTS - 1 loop
            v_beats := f_beats(p);

            --------------------------------------------------------------------
            -- ENC: nonce + PT beats (TKEEP partial on the last beat)
            --------------------------------------------------------------------
            e_nonce       <= c_IVS(p);
            e_nonce_valid <= '1';
            wait until rising_edge(clk);
            e_nonce_valid <= '0';

            for i in 1 to 2000 loop
                wait until rising_edge(clk);
                exit when e_s_tready = '1';
            end loop;
            assert e_s_tready = '1'
                report "pkt " & integer'image(p) & ": ENC never opened"
                severity failure;

            sv_e_cnt := 0;  sv_e_done := false;

            for b in 0 to v_beats - 1 loop
                e_s_tdata <= byte_reverse(c_PT(p, b));
                if b = v_beats - 1 then
                    e_s_tkeep <= f_keep(f_tail(p));
                    e_s_tlast <= '1';
                else
                    e_s_tkeep <= (others => '1');
                    e_s_tlast <= '0';
                end if;
                e_s_tvalid <= '1';
                wait until rising_edge(clk) and e_s_tready = '1';
                e_s_tvalid <= '0';
                e_s_tlast  <= '0';
            end loop;

            for i in 1 to 3000 loop
                wait until rising_edge(clk);
                exit when sv_e_done;
            end loop;
            assert sv_e_done
                report "pkt " & integer'image(p) & ": ENC output never completed"
                severity failure;
            assert sv_e_cnt = v_beats + 1
                report "pkt " & integer'image(p) & ": ENC emitted "
                     & integer'image(sv_e_cnt) & " beats, expected "
                     & integer'image(v_beats + 1) severity failure;

            -- CT beats: compare only the kept lanes; check TKEEP pass-through
            for b in 0 to v_beats - 1 loop
                if b = v_beats - 1 then
                    v_keep := f_keep(f_tail(p));
                else
                    v_keep := (others => '1');
                end if;
                if sv_e_keep(b) /= v_keep then
                    note_mismatch(p, b, "CT TKEEP",
                                  x"0000000000000000000000000000" & sv_e_keep(b),
                                  x"0000000000000000000000000000" & v_keep);
                end if;
                if not f_match(sv_e_mem(b), byte_reverse(c_CT(p, b)), v_keep) then
                    note_mismatch(p, b, "CT", sv_e_mem(b), byte_reverse(c_CT(p, b)));
                end if;
            end loop;
            -- ICV beat: full compare
            if sv_e_mem(v_beats) /= byte_reverse(c_TAG(p)) then
                note_mismatch(p, v_beats, "TAG", sv_e_mem(v_beats), byte_reverse(c_TAG(p)));
            end if;

            --------------------------------------------------------------------
            -- DEC round-trip: replay the captured packet with the same TKEEP
            --------------------------------------------------------------------
            d_nonce       <= c_IVS(p);
            d_nonce_valid <= '1';
            wait until rising_edge(clk);
            d_nonce_valid <= '0';

            sv_d_cnt := 0;  sv_d_done := false;  sv_d_auth := 'U';

            for b in 0 to v_beats loop      -- CT beats + ICV
                d_s_tdata <= sv_e_mem(b);
                d_s_tkeep <= sv_e_keep(b);
                if b = v_beats then
                    d_s_tlast <= '1';
                else
                    d_s_tlast <= '0';
                end if;
                d_s_tvalid <= '1';
                wait until rising_edge(clk) and d_s_tready = '1';
                d_s_tvalid <= '0';
                d_s_tlast  <= '0';
            end loop;

            for i in 1 to 3000 loop
                wait until rising_edge(clk);
                exit when sv_d_done;
            end loop;
            assert sv_d_done
                report "pkt " & integer'image(p) & ": DEC output never completed"
                severity failure;
            assert sv_d_cnt = v_beats
                report "pkt " & integer'image(p) & ": DEC emitted "
                     & integer'image(sv_d_cnt) & " beats, expected "
                     & integer'image(v_beats) severity failure;

            if sv_d_auth /= '1' then
                v_fail := v_fail + 1;
                write(v_l, string'("  pkt "));
                write(v_l, p);
                write(v_l, string'(": DEC auth FAILED on a clean partial-beat packet"));
                writeline(output, v_l);
            end if;
            for b in 0 to v_beats - 1 loop
                if b = v_beats - 1 then
                    v_keep := f_keep(f_tail(p));
                else
                    v_keep := (others => '1');
                end if;
                if not f_match(sv_d_mem(b), byte_reverse(c_PT(p, b)), v_keep) then
                    note_mismatch(p, b, "PT", sv_d_mem(b), byte_reverse(c_PT(p, b)));
                end if;
            end loop;

            report "pkt " & integer'image(p) & " ("
                 & integer'image(c_BYTES(p)) & " B, tail "
                 & integer'image(f_tail(p)) & " B): ENC KAT + DEC round-trip done";
        end loop;

        if v_fail = 0 then
            report "==== tb_gcm_kat_tkeep (" & G_WRAPPER_KIND
                 & "): ALL PASS -- partial-TKEEP CT/TAG bit-exact + auth OK ====";
        else
            report "==== tb_gcm_kat_tkeep FAIL: " & integer'image(v_fail)
                 & " mismatches ====" severity failure;
        end if;
        finish(0);
    end process;

    p_TIMEOUT : process
    begin
        wait for 500 us;
        report "Hard timeout" severity failure;
        finish(1);
    end process;

end architecture;
