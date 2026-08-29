----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Design Name   : tb_gcm_kat_len
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Length-sweep known-answer test for the encryption chain.
--
--                 Drives  header(16 B) || AAD(AAD_BYTES) || PT(PT_BYTES)  with
--                 the deterministic pattern (i*7+13) mod 256 and compares the
--                 ciphertext and the tag against a golden vector produced by a
--                 software AES-128-GCM reference (ref/gen_vectors.py),
--                 read from VEC_FILE as two hex lines: <CT> then <TAG>.
--
--                 Key / IV are fixed:
--                   K  = feffe9928665731c6d6a8f9467308308
--                   IV = cafebabefacedbaddecaf888   (96-bit -> J0)
--
--                 Sweeping AAD_BYTES and PT_BYTES over every residue mod 16
--                 proves the partial-block (zero-padding) path is standard
--                 compliant, not just the one length in NIST test case 4.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_gcm_kat_len is
    generic (
        AES_BITS  : integer  := 128;      -- 128 or 256
        AAD_BYTES : positive := 20;
        PT_BYTES  : positive := 60;
        VEC_FILE  : string   := "vec.txt"
    );
end entity;

architecture sim of tb_gcm_kat_len is

    constant c_DW        : positive := 128;
    constant c_BUS_BYTES : positive := 16;
    constant c_HDR_BYTES : positive := 16;
    constant c_ICV_BYTES : positive := 16;

    constant c_IN_TOTAL  : positive := c_HDR_BYTES + AAD_BYTES + PT_BYTES;
    constant c_OUT_TOTAL : positive := c_IN_TOTAL + c_ICV_BYTES;
    constant c_IN_BEATS  : positive := (c_IN_TOTAL + c_BUS_BYTES - 1) / c_BUS_BYTES;

    -- The core takes the key in the low AES_BITS bits of the 256-bit port.
    constant c_KEY128 : std_logic_vector(127 downto 0) := x"feffe9928665731c6d6a8f9467308308";
    constant c_KEY256 : std_logic_vector(255 downto 0) :=
        x"feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308";
    constant c_NONCE  : std_logic_vector(95 downto 0)  := x"cafebabefacedbaddecaf888";

    type byte_arr_t is array(natural range <>) of std_logic_vector(7 downto 0);

    -- golden ciphertext / tag, filled from VEC_FILE at time 0

    function pattern_byte(i : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((i*7 + 13) mod 256, 8));
    end function;

    function hex_val(c : character) return natural is
    begin
        case c is
            when '0' to '9' => return character'pos(c) - character'pos('0');
            when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
            when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
            when others     => return 0;
        end case;
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

    -- golden ciphertext / tag, filled from VEC_FILE at time 0
    signal sv_ct  : byte_arr_t(0 to PT_BYTES-1);
    signal sv_tag : byte_arr_t(0 to c_ICV_BYTES-1);

    signal vec_ready : boolean := false;
    signal out_done  : boolean := false;
    signal out_pass  : boolean := true;

begin

    u_dut : entity work.top_gcm_enc
        generic map (
            DATA_WIDTH   => c_DW,
            AES_BITS     => AES_BITS,
            BYPASS_BYTES => c_HDR_BYTES,
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
    -- Load the golden vector
    ----------------------------------------------------------------------------
    p_LOAD : process
        file     f     : text;
        variable l     : line;
        variable v_st  : file_open_status;
        variable v_ct  : byte_arr_t(0 to PT_BYTES-1);
        variable v_tag : byte_arr_t(0 to c_ICV_BYTES-1);
    begin
        file_open(v_st, f, VEC_FILE, read_mode);
        assert v_st = open_ok report "cannot open " & VEC_FILE severity failure;

        readline(f, l);                                   -- ciphertext
        for k in 0 to PT_BYTES-1 loop
            v_ct(k) := std_logic_vector(to_unsigned(
                           hex_val(l.all(2*k+1)) * 16 + hex_val(l.all(2*k+2)), 8));
        end loop;

        readline(f, l);                                   -- tag
        for k in 0 to c_ICV_BYTES-1 loop
            v_tag(k) := std_logic_vector(to_unsigned(
                            hex_val(l.all(2*k+1)) * 16 + hex_val(l.all(2*k+2)), 8));
        end loop;

        file_close(f);
        sv_ct     <= v_ct;
        sv_tag    <= v_tag;
        vec_ready <= true;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Key / IV, then the packet
    ----------------------------------------------------------------------------
    p_MASTER : process
        variable v_data : std_logic_vector(c_DW-1 downto 0);
        variable v_keep : std_logic_vector(c_BUS_BYTES-1 downto 0);
        variable v_idx  : natural;
    begin
        wait until i_rstn = '1';
        wait until rising_edge(i_clk);

        if AES_BITS = 256 then
            i_key(255 downto 0) <= c_KEY256;
        else
            i_key(127 downto 0) <= c_KEY128;
        end if;
        i_nonce <= c_NONCE;
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
                    v_data(8*lane+7 downto 8*lane) := pattern_byte(v_idx);
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
    -- Compare CT + TAG against the golden vector
    ----------------------------------------------------------------------------
    p_SINK : process
        variable v_col     : byte_arr_t(0 to c_OUT_TOTAL + 4*c_BUS_BYTES - 1);
        variable v_cnt     : natural := 0;
        variable v_ok      : boolean := true;
        variable v_ct_bad  : natural := 0;
        variable v_tag_bad : natural := 0;
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
            -- header + AAD must travel in the clear
            for i in 0 to c_HDR_BYTES + AAD_BYTES - 1 loop
                if v_col(i) /= pattern_byte(i) then
                    report "CLEAR-TEXT mismatch at byte " & integer'image(i) severity error;
                    v_ok := false;
                end if;
            end loop;
            for k in 0 to PT_BYTES-1 loop
                if v_col(c_HDR_BYTES + AAD_BYTES + k) /= sv_ct(k) then
                    v_ct_bad := v_ct_bad + 1;
                end if;
            end loop;
            for k in 0 to c_ICV_BYTES-1 loop
                if v_col(c_HDR_BYTES + AAD_BYTES + PT_BYTES + k) /= sv_tag(k) then
                    v_tag_bad := v_tag_bad + 1;
                end if;
            end loop;

            if v_ct_bad /= 0 then
                report "CT mismatch in " & integer'image(v_ct_bad) & "/" &
                       integer'image(PT_BYTES) & " bytes" severity error;
                v_ok := false;
            end if;
            if v_tag_bad /= 0 then
                report "TAG mismatch in " & integer'image(v_tag_bad) & "/16 bytes" severity error;
                v_ok := false;
            end if;
        end if;

        out_pass <= v_ok;
        out_done <= true;
        wait;
    end process;

    p_CHECK : process
    begin
        wait until out_done;
        report "KAT-LEN  AAD=" & integer'image(AAD_BYTES) &
               " (mod16=" & integer'image(AAD_BYTES mod 16) & ")" &
               "  PT=" & integer'image(PT_BYTES) &
               " (mod16=" & integer'image(PT_BYTES mod 16) & ")";
        if out_pass then
            report "RESULT: PASS";
        else
            report "RESULT: FAIL" severity error;
        end if;
        finish;
    end process;

    p_TIMEOUT : process
    begin
        wait for 4 ms;
        report "RESULT: FAIL (timeout)" severity error;
        finish;
    end process;

end architecture;
