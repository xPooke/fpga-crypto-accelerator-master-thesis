----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : gcm_enc / gcm_dec
-- Module Name   : gcm_enc / gcm_dec - rtl
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : gcm_enc / gcm_dec composites: gcm_*_glue + AES_algorithm wired back
--                 together, so a testbench can drive one entity instead of the split
--                 pair.
--
--                 The suite was written against the classic interface (AES_BITS key,
--                 96-bit nonce) and so do the packaged cores, so only the key is
--                 widened here:
--                   i_key   (AES_BITS) -> 256-bit key port, zero-extended
--                   i_tick tied '0'; the in-proc / counter outputs left open.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gcm_enc is
    generic (
        AES_BITS     : integer  := 128;
        ROUND_STYLE  : string   := "BRAM";
        FLOW_STYLE   : string   := "GLOBAL";
        WRAPPER_KIND : string   := "UNROLLED";
        NUM_CORES    : integer  := 4;
        AAD_BEATS    : natural  := 0;
        AAD_BYTES    : natural  := 0;   -- 0 = AAD_BEATS full blocks
        MULT_CYCLES  : integer  := 2;   -- GHASH multiply timing: 1 or 2 cycles
        DATA_WIDTH   : positive := 128
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;
        i_key         : in  std_logic_vector(AES_BITS-1 downto 0);
        i_key_valid   : in  std_logic;
        i_nonce       : in  std_logic_vector(95 downto 0);
        i_nonce_valid : in  std_logic;
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity;

architecture rtl of gcm_enc is
    -- AAD_BYTES = 0 means "AAD_BEATS full blocks", which is what the older
    -- testbenches assume; anything else is a byte-exact AAD length.
    function aad_len_bytes (constant beats : natural; constant bytes : natural;
                            constant width : positive) return natural is
    begin
        if bytes > 0 then
            return bytes;
        else
            return beats * (width / 8);
        end if;
    end function;

    signal w_key       : std_logic_vector(255 downto 0);
    -- crypto boundary
    signal c_key       : std_logic_vector(255 downto 0);
    signal c_key_valid : std_logic;
    signal c_nonce        : std_logic_vector(95 downto 0);
    signal c_nonce_valid  : std_logic;
    signal c_pt_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal c_pt_tkeep  : std_logic_vector(DATA_WIDTH/8-1 downto 0);
    signal c_pt_tvalid, c_pt_tlast, c_pt_tready : std_logic;
    signal c_ct_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal c_ct_tkeep  : std_logic_vector(DATA_WIDTH/8-1 downto 0);
    signal c_ct_tvalid, c_ct_tlast, c_ct_tready : std_logic;
    signal c_H, c_EJ0  : std_logic_vector(127 downto 0);
    signal c_H_valid, c_EJ0_valid, c_in_proc : std_logic;
    signal c_h_stale : std_logic;
begin
    w_key <= std_logic_vector(resize(unsigned(i_key), 256));

    u_glue : entity work.gcm_enc_glue
        generic map (AAD_BEATS => AAD_BEATS,
                     AAD_BYTES  => aad_len_bytes(AAD_BEATS, AAD_BYTES, DATA_WIDTH),
                     DATA_WIDTH => DATA_WIDTH,
                     MULT_CYCLES => MULT_CYCLES)
        port map (
            i_clk => i_clk, i_rstn => i_rstn, i_tick => '0',
            i_key => w_key, i_key_valid => i_key_valid,
            i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,
            s_axis_tdata => s_axis_tdata, s_axis_tkeep => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid, s_axis_tlast => s_axis_tlast,
            s_axis_tready => s_axis_tready,
            m_axis_tdata => m_axis_tdata, m_axis_tkeep => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid, m_axis_tlast => m_axis_tlast,
            m_axis_tready => m_axis_tready,
            o_ENC_in_proc => open, o_TxENC => open,
            o_crypto_key => c_key, o_crypto_key_valid => c_key_valid,
            o_crypto_nonce => c_nonce, o_crypto_nonce_valid => c_nonce_valid,
            m_pt_axis_tdata => c_pt_tdata, m_pt_axis_tkeep => c_pt_tkeep,
            m_pt_axis_tvalid => c_pt_tvalid, m_pt_axis_tlast => c_pt_tlast,
            m_pt_axis_tready => c_pt_tready,
            s_ct_axis_tdata => c_ct_tdata, s_ct_axis_tkeep => c_ct_tkeep,
            s_ct_axis_tvalid => c_ct_tvalid, s_ct_axis_tlast => c_ct_tlast,
            s_ct_axis_tready => c_ct_tready,
            i_crypto_H => c_H, i_crypto_H_valid => c_H_valid,
            i_crypto_E_k => c_EJ0, i_crypto_E_k_valid => c_EJ0_valid,
            i_crypto_h_stale => c_h_stale,
            i_crypto_in_proc => c_in_proc
        );

    u_alg : entity work.AES_algorithm
        generic map (AES_BITS => AES_BITS, ROUND_STYLE => ROUND_STYLE,
                     FLOW_STYLE => FLOW_STYLE, WRAPPER_KIND => WRAPPER_KIND,
                     NUM_CORES => NUM_CORES)
        port map (
            i_clk => i_clk, i_rstn => i_rstn,
            i_key => c_key, i_key_valid => c_key_valid,
            i_nonce => c_nonce, i_nonce_valid => c_nonce_valid,
            s_axis_tdata => c_pt_tdata, s_axis_tvalid => c_pt_tvalid,
            s_axis_tready => c_pt_tready, s_axis_tlast => c_pt_tlast,
            s_axis_tkeep => c_pt_tkeep,
            m_axis_tdata => c_ct_tdata, m_axis_tvalid => c_ct_tvalid,
            m_axis_tready => c_ct_tready, m_axis_tlast => c_ct_tlast,
            m_axis_tkeep => c_ct_tkeep,
            o_H => c_H, o_H_valid => c_H_valid,
            o_E_k => c_EJ0, o_E_k_valid => c_EJ0_valid,
            o_h_stale => c_h_stale,
            o_encryption_in_proc => c_in_proc
        );
end architecture;

----------------------------------------------------------------------------------
-- gcm_dec  =  gcm_dec_glue + AES_algorithm
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gcm_dec is
    generic (
        AES_BITS     : integer  := 128;
        ROUND_STYLE  : string   := "BRAM";
        FLOW_STYLE   : string   := "GLOBAL";
        WRAPPER_KIND : string   := "UNROLLED";
        NUM_CORES    : integer  := 4;
        AAD_BEATS    : natural  := 0;
        AAD_BYTES    : natural  := 0;   -- 0 = AAD_BEATS full blocks
        MULT_CYCLES  : integer  := 2;   -- GHASH multiply timing: 1 or 2 cycles
        DATA_WIDTH   : positive := 128
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;
        i_key         : in  std_logic_vector(AES_BITS-1 downto 0);
        i_key_valid   : in  std_logic;
        i_nonce       : in  std_logic_vector(95 downto 0);
        i_nonce_valid : in  std_logic;
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic;
        o_auth_ok     : out std_logic;
        o_dec_done    : out std_logic
    );
end entity;

architecture rtl of gcm_dec is
    -- AAD_BYTES = 0 means "AAD_BEATS full blocks", which is what the older
    -- testbenches assume; anything else is a byte-exact AAD length.
    function aad_len_bytes (constant beats : natural; constant bytes : natural;
                            constant width : positive) return natural is
    begin
        if bytes > 0 then
            return bytes;
        else
            return beats * (width / 8);
        end if;
    end function;

    signal w_key       : std_logic_vector(255 downto 0);
    signal c_key       : std_logic_vector(255 downto 0);
    signal c_key_valid : std_logic;
    signal c_nonce        : std_logic_vector(95 downto 0);
    signal c_nonce_valid  : std_logic;
    signal c_ct_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal c_ct_tkeep  : std_logic_vector(DATA_WIDTH/8-1 downto 0);
    signal c_ct_tvalid, c_ct_tlast, c_ct_tready : std_logic;
    signal c_pt_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal c_pt_tkeep  : std_logic_vector(DATA_WIDTH/8-1 downto 0);
    signal c_pt_tvalid, c_pt_tlast, c_pt_tready : std_logic;
    signal c_H, c_EJ0  : std_logic_vector(127 downto 0);
    signal c_H_valid, c_EJ0_valid, c_in_proc : std_logic;
    signal c_h_stale : std_logic;
begin
    w_key <= std_logic_vector(resize(unsigned(i_key), 256));

    u_glue : entity work.gcm_dec_glue
        generic map (AAD_BEATS => AAD_BEATS,
                     AAD_BYTES  => aad_len_bytes(AAD_BEATS, AAD_BYTES, DATA_WIDTH),
                     DATA_WIDTH => DATA_WIDTH,
                     MULT_CYCLES => MULT_CYCLES)
        port map (
            i_clk => i_clk, i_rstn => i_rstn,
            i_key => w_key, i_key_valid => i_key_valid,
            i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,
            s_axis_tdata => s_axis_tdata, s_axis_tkeep => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid, s_axis_tlast => s_axis_tlast,
            s_axis_tready => s_axis_tready,
            m_axis_tdata => m_axis_tdata, m_axis_tkeep => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid, m_axis_tlast => m_axis_tlast,
            m_axis_tready => m_axis_tready,
            o_auth_ok => o_auth_ok, o_dec_done => o_dec_done,
            o_DEC_in_proc => open,
            o_crypto_key => c_key, o_crypto_key_valid => c_key_valid,
            o_crypto_nonce => c_nonce, o_crypto_nonce_valid => c_nonce_valid,
            m_ct_axis_tdata => c_ct_tdata, m_ct_axis_tkeep => c_ct_tkeep,
            m_ct_axis_tvalid => c_ct_tvalid, m_ct_axis_tlast => c_ct_tlast,
            m_ct_axis_tready => c_ct_tready,
            s_pt_axis_tdata => c_pt_tdata, s_pt_axis_tkeep => c_pt_tkeep,
            s_pt_axis_tvalid => c_pt_tvalid, s_pt_axis_tlast => c_pt_tlast,
            s_pt_axis_tready => c_pt_tready,
            i_crypto_H => c_H, i_crypto_H_valid => c_H_valid,
            i_crypto_E_k => c_EJ0, i_crypto_E_k_valid => c_EJ0_valid,
            i_crypto_h_stale => c_h_stale,
            i_crypto_in_proc => c_in_proc
        );

    u_alg : entity work.AES_algorithm
        generic map (AES_BITS => AES_BITS, ROUND_STYLE => ROUND_STYLE,
                     FLOW_STYLE => FLOW_STYLE, WRAPPER_KIND => WRAPPER_KIND,
                     NUM_CORES => NUM_CORES)
        port map (
            i_clk => i_clk, i_rstn => i_rstn,
            i_key => c_key, i_key_valid => c_key_valid,
            i_nonce => c_nonce, i_nonce_valid => c_nonce_valid,
            s_axis_tdata => c_ct_tdata, s_axis_tvalid => c_ct_tvalid,
            s_axis_tready => c_ct_tready, s_axis_tlast => c_ct_tlast,
            s_axis_tkeep => c_ct_tkeep,
            m_axis_tdata => c_pt_tdata, m_axis_tvalid => c_pt_tvalid,
            m_axis_tready => c_pt_tready, m_axis_tlast => c_pt_tlast,
            m_axis_tkeep => c_pt_tkeep,
            o_H => c_H, o_H_valid => c_H_valid,
            o_E_k => c_EJ0, o_E_k_valid => c_EJ0_valid,
            o_h_stale => c_h_stale,
            o_encryption_in_proc => c_in_proc
        );
end architecture;
