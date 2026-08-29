----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_wrap_keyrace
-- Module Name   : tb_wrap_keyrace - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : AES_algorithm standalone key-swap offset sweep, with NO glue. It
--                 mimics the glue's GHASH gate with a single rule -
--                 m_axis_tready <= not o_h_stale - which reproduces CT back-pressure
--                 while H is stale. A freeze here is therefore a property of the
--                 WRAPPER, not of the glue.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_wrap_keyrace is
    generic (
        G_KIND     : string  := "MULTICORE";
        NUM_CORES  : integer := 4;
        PKT_BLOCKS : integer := 4;
        NUM_PKTS   : integer := 30;
        WARMUP     : integer := 4;
        KEY_OFF    : integer := 2;     -- key pulse cycles after the packet's IV
        C_TIMEOUT  : integer := 4000
    );
end entity;

architecture sim of tb_wrap_keyrace is
    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';
    signal i_key       : std_logic_vector(255 downto 0) := (others=>'0');
    signal i_key_valid : std_logic := '0';
    signal i_nonce        : std_logic_vector(95 downto 0) := (others=>'0');
    signal i_nonce_valid  : std_logic := '0';
    signal s_tdata  : std_logic_vector(127 downto 0) := (others=>'0');
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tlast  : std_logic := '0';
    signal s_tkeep  : std_logic_vector(15 downto 0) := (others=>'1');
    signal m_tdata  : std_logic_vector(127 downto 0);
    signal m_tvalid : std_logic;
    signal m_tready : std_logic;
    signal m_tlast  : std_logic;
    signal m_tkeep  : std_logic_vector(15 downto 0);
    signal o_H, o_Ek : std_logic_vector(127 downto 0);
    signal o_Hv, o_Ekv, o_inproc, o_hstale : std_logic;
    signal r_out_beats : integer := 0;
    signal r_pkts_out  : integer := 0;
begin
    u : entity work.AES_algorithm
        generic map (AES_BITS=>128, ROUND_STYLE=>"LUT", FLOW_STYLE=>"GLOBAL",
                     WRAPPER_KIND=>G_KIND, NUM_CORES=>NUM_CORES)
        port map (
            i_clk=>clk, i_rstn=>rstn,
            i_key=>i_key, i_key_valid=>i_key_valid, i_nonce=>i_nonce, i_nonce_valid=>i_nonce_valid,
            s_axis_tdata=>s_tdata, s_axis_tvalid=>s_tvalid, s_axis_tready=>s_tready,
            s_axis_tlast=>s_tlast, s_axis_tkeep=>s_tkeep,
            m_axis_tdata=>m_tdata, m_axis_tvalid=>m_tvalid, m_axis_tready=>m_tready,
            m_axis_tlast=>m_tlast, m_axis_tkeep=>m_tkeep,
            o_H=>o_H, o_H_valid=>o_Hv, o_E_k=>o_Ek, o_E_k_valid=>o_Ekv,
            o_h_stale=>o_hstale, o_encryption_in_proc=>o_inproc);

    clk  <= not clk after 5 ns;
    rstn <= '0', '1' after 53 ns;

    -- THE GATE MIMIC: downstream accepts CT only when H is fresh (exactly the glue rule).
    m_tready <= not o_hstale;

    p_obs : process(clk) begin
        if rising_edge(clk) then
            if rstn='0' then r_out_beats<=0; r_pkts_out<=0;
            else
                if m_tvalid='1' and m_tready='1' then
                    r_out_beats <= r_out_beats+1;
                    if m_tlast='1' then r_pkts_out <= r_pkts_out+1; end if;
                end if;
            end if;
        end if;
    end process;

    p_stim : process
        procedure waitc(constant k:integer) is begin
            for i in 1 to k loop wait until rising_edge(clk); end loop; end;
        procedure pulse_iv(constant n:integer) is begin
            i_nonce <= (others=>'0'); i_nonce(15 downto 0) <= std_logic_vector(to_unsigned(n,16));
            i_nonce(95 downto 64) <= x"cafebabe"; i_nonce_valid<='1';
            wait until rising_edge(clk); i_nonce_valid<='0'; end;
        procedure pulse_key(constant n:integer) is begin
            i_key <= (others=>'0'); i_key(31 downto 0) <= std_logic_vector(to_unsigned(n+1,32));
            i_key_valid<='1'; wait until rising_edge(clk); i_key_valid<='0'; end;
        procedure send_pt(constant last:boolean; constant pk:integer) is
            variable wd:integer:=0; begin
            s_tdata<=(others=>'0'); s_tkeep<=(others=>'1');
            if last then s_tlast<='1'; else s_tlast<='0'; end if; s_tvalid<='1';
            loop wait until rising_edge(clk); exit when s_tready='1';
                wd:=wd+1; assert wd<C_TIMEOUT
                  report "FREEZE - s_tready stuck (wrapper wedged) pkt="&integer'image(pk)
                  severity failure; end loop;
            s_tvalid<='0'; s_tlast<='0'; end;
    begin
        wait until rstn='1'; waitc(2);
        i_key<=(others=>'0'); i_key(31 downto 0)<=x"00000001"; i_key_valid<='1';
        wait until rising_edge(clk); i_key_valid<='0';
        for p in 0 to NUM_PKTS-1 loop
            pulse_iv(p+1);
            if p>=WARMUP then waitc(KEY_OFF); pulse_key(p+10); end if;
            for b in 0 to PKT_BLOCKS-1 loop send_pt(b=PKT_BLOCKS-1, p); end loop;
        end loop;
        waitc(20);
        if r_pkts_out=NUM_PKTS then report "RESULT: PASS" severity note;
        else report "RESULT: FAIL pkts="&integer'image(r_pkts_out) severity failure; end if;
        finish;
    end process;

    p_to : process begin wait for 30 ms;
        report "FREEZE - global timeout" severity failure; finish; end process;
end architecture;
