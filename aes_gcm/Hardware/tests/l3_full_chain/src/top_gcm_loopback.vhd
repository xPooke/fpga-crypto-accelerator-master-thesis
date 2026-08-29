----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : top_gcm_loopback
-- Module Name   : top_gcm_loopback - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : End-to-end loopback: all 10 IP cores.
--
--   plain packet ──► top_gcm_enc (5 cores) ──► protected packet ──►
--                                              top_gcm_dec (5 cores) ──► plain packet
--
--   The recovered packet must be byte-identical to the original and o_auth_ok
--   must be '1'.  This exercises SPLIT_demux, AXIS_full_skid_buffer,
--   gcm_enc_glue, gcm_dec_glue, AES_algorithm (x2) and MERGE_mux together.
--
-- Dependencies  : work.top_gcm_enc, work.top_gcm_dec
--
-- Revision      :
--   0.01 - July 2026 - File Created
--   0.02 - August 2026 - Bypass = 0 is now supported: added the BYPASS_EN
--          generic, passed through to top_gcm_enc / top_gcm_dec.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top_gcm_loopback is
    generic (
        DATA_WIDTH   : positive := 128;
        BYPASS_EN    : boolean  := true;      -- true = bypass segment present; false = disabled
        BYPASS_BYTES : positive := 50;
        AAD_BYTES    : positive := 20;
        AES_BITS     : integer  := 128;
        ROUND_STYLE  : string   := "BRAM";
        FLOW_STYLE   : string   := "GLOBAL";
        WRAPPER_KIND : string   := "UNROLLED";
        NUM_CORES    : integer  := 4
    );
    port (
        i_clk  : in  std_logic;
        i_rstn : in  std_logic;

        i_key       : in  std_logic_vector(255 downto 0);
        i_key_valid : in  std_logic;
        i_nonce        : in  std_logic_vector(95 downto 0);
        i_nonce_valid  : in  std_logic;

        -- AXIS slave: plain packet  header || AAD || PT
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXIS master: recovered plain packet (must equal the input)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic;

        -- Side-band
        o_auth_ok  : out std_logic;
        o_dec_done : out std_logic
    );
end entity;

architecture rtl of top_gcm_loopback is

    constant c_BUS_BYTES : positive := DATA_WIDTH / 8;

    -- ENC -> DEC : the protected packet (header || AAD || CT || ICV)
    signal w_prot_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_prot_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_prot_tvalid : std_logic;
    signal w_prot_tlast  : std_logic;
    signal w_prot_tready : std_logic;

    signal w_enc_in_proc : std_logic;
    signal w_txenc       : std_logic_vector(31 downto 0);
    signal w_dec_in_proc : std_logic;

begin

    --------------------------------------------------------------------------
    -- Cores 1-5 : encryption chain
    --------------------------------------------------------------------------
    u_enc : entity work.top_gcm_enc
        generic map (
            DATA_WIDTH   => DATA_WIDTH,
            BYPASS_EN    => BYPASS_EN,
            BYPASS_BYTES => BYPASS_BYTES,
            AAD_BYTES    => AAD_BYTES,
            AES_BITS     => AES_BITS,
            ROUND_STYLE  => ROUND_STYLE,
            FLOW_STYLE   => FLOW_STYLE,
            WRAPPER_KIND => WRAPPER_KIND,
            NUM_CORES    => NUM_CORES
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            i_key       => i_key,
            i_key_valid => i_key_valid,
            i_nonce        => i_nonce,
            i_nonce_valid  => i_nonce_valid,

            s_axis_tdata  => s_axis_tdata,
            s_axis_tkeep  => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tready => s_axis_tready,

            m_axis_tdata  => w_prot_tdata,
            m_axis_tkeep  => w_prot_tkeep,
            m_axis_tvalid => w_prot_tvalid,
            m_axis_tlast  => w_prot_tlast,
            m_axis_tready => w_prot_tready,

            o_ENC_in_proc => w_enc_in_proc,
            o_TxENC       => w_txenc
        );

    --------------------------------------------------------------------------
    -- Cores 6-10 : decryption chain (fed by the protected packet)
    --------------------------------------------------------------------------
    u_dec : entity work.top_gcm_dec
        generic map (
            DATA_WIDTH   => DATA_WIDTH,
            BYPASS_EN    => BYPASS_EN,
            BYPASS_BYTES => BYPASS_BYTES,
            AAD_BYTES    => AAD_BYTES,
            AES_BITS     => AES_BITS,
            ROUND_STYLE  => ROUND_STYLE,
            FLOW_STYLE   => FLOW_STYLE,
            WRAPPER_KIND => WRAPPER_KIND,
            NUM_CORES    => NUM_CORES
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            i_key       => i_key,
            i_key_valid => i_key_valid,
            i_nonce        => i_nonce,
            i_nonce_valid  => i_nonce_valid,

            s_axis_tdata  => w_prot_tdata,
            s_axis_tkeep  => w_prot_tkeep,
            s_axis_tvalid => w_prot_tvalid,
            s_axis_tlast  => w_prot_tlast,
            s_axis_tready => w_prot_tready,

            m_axis_tdata  => m_axis_tdata,
            m_axis_tkeep  => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tlast  => m_axis_tlast,
            m_axis_tready => m_axis_tready,

            o_auth_ok     => o_auth_ok,
            o_dec_done    => o_dec_done,
            o_DEC_in_proc => w_dec_in_proc
        );

end architecture;
