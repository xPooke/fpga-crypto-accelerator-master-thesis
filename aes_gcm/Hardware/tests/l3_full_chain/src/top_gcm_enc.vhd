----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : top_gcm_enc
-- Module Name   : top_gcm_enc - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Full AES-GCM encryption datapath - 5 IP cores wired together.
--
--   s_axis (bypass || AAD || PT)
--        |
--   SPLIT_demux ---- m_bypass ----> AXIS_full_skid_buffer ----------+
--        |                                                          |
--        +-------- m_crypto (AAD || PT) ---> gcm_enc_glue           |
--                                              ^   |                |
--                     crypto boundary (PT/CT + | H/E_k)             |
--                                              |   v                v
--                                          AES_algorithm        MERGE_mux
--                                                                   |
--                                                        m_axis (bypass || AAD || CT || ICV)
--
--   Cores: SPLIT_demux, AXIS_full_skid_buffer, gcm_enc_glue, AES_algorithm,
--          MERGE_mux.
--
-- Dependencies  : work.SPLIT_demux, work.MERGE_mux, work.AXIS_full_skid_buffer,
--                 work.gcm_enc_glue, work.AES_algorithm
--
-- Revision      :
--   0.01 - July 2026 - File Created
--   0.02 - August 2026 - Bypass = 0 is now supported: added the BYPASS_EN
--          generic (passed to SPLIT_demux and MERGE_mux). When false the skid
--          buffer and the whole bypass path are removed by a generate.
--
-- Additional Comments :
--   Active-low reset (i_rstn).  AES_algorithm has a fixed 128-bit AXIS, so
--   DATA_WIDTH must be 128 for this chain.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top_gcm_enc is
    generic (
        DATA_WIDTH   : positive := 128;
        BYPASS_EN    : boolean  := true;      -- true = bypass segment present; false = disabled
        BYPASS_BYTES : positive := 50;        -- bypass segment bytes (used only when BYPASS_EN)
        AAD_BYTES    : positive := 20;        -- AAD bytes
        AES_BITS     : integer  := 128;       -- 128 or 256
        ROUND_STYLE  : string   := "BRAM";    -- "BRAM" or "LUT"
        FLOW_STYLE   : string   := "GLOBAL";  -- "GLOBAL" or "PER_STAGE"
        WRAPPER_KIND : string   := "UNROLLED";-- "UNROLLED" or "MULTICORE"
        NUM_CORES    : integer  := 4          -- MULTICORE only
    );
    port (
        i_clk  : in  std_logic;
        i_rstn : in  std_logic;

        -- Key / IV config (256-bit key; LSB AES_BITS bits used)
        i_key       : in  std_logic_vector(255 downto 0);
        i_key_valid : in  std_logic;
        i_nonce        : in  std_logic_vector(95 downto 0);
        i_nonce_valid  : in  std_logic;

        -- AXIS slave: plain packet  bypass || AAD || PT  (TLAST on last PT beat)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXIS master: protected packet  bypass || AAD || CT || ICV
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic;

        -- Side-band
        o_ENC_in_proc : out std_logic;
        o_TxENC       : out std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of top_gcm_enc is

    constant c_BUS_BYTES : positive := DATA_WIDTH / 8;
    constant c_AAD_BEATS : natural  := (AAD_BYTES + c_BUS_BYTES - 1) / c_BUS_BYTES;

    -- SPLIT_demux -> skid (bypass path)
    signal w_byp_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_byp_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_byp_tvalid : std_logic;
    signal w_byp_tlast  : std_logic;
    signal w_byp_tready : std_logic;

    -- skid -> MERGE_mux (bypass path)
    signal w_skid_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_skid_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_skid_tvalid : std_logic;
    signal w_skid_tlast  : std_logic;
    signal w_skid_tready : std_logic;

    -- SPLIT_demux -> gcm_enc_glue  (AAD || PT)
    signal w_cry_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_cry_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_cry_tvalid : std_logic;
    signal w_cry_tlast  : std_logic;
    signal w_cry_tready : std_logic;

    -- gcm_enc_glue -> MERGE_mux  (AAD || CT || ICV)
    signal w_gcm_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_gcm_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_gcm_tvalid : std_logic;
    signal w_gcm_tlast  : std_logic;
    signal w_gcm_tready : std_logic;

    -- crypto boundary: glue -> AES (PT)
    signal w_pt_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_pt_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_pt_tvalid : std_logic;
    signal w_pt_tlast  : std_logic;
    signal w_pt_tready : std_logic;

    -- crypto boundary: AES -> glue (CT)
    signal w_ct_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_ct_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_ct_tvalid : std_logic;
    signal w_ct_tlast  : std_logic;
    signal w_ct_tready : std_logic;

    -- crypto boundary: key / IV + side-band
    signal w_crypto_key       : std_logic_vector(255 downto 0);
    signal w_crypto_key_valid : std_logic;
    signal w_crypto_IV        : std_logic_vector(95 downto 0);
    signal w_crypto_IV_valid  : std_logic;
    signal w_crypto_H         : std_logic_vector(127 downto 0);
    signal w_crypto_H_valid   : std_logic;
    signal w_crypto_E_k       : std_logic_vector(127 downto 0);
    signal w_crypto_E_k_valid : std_logic;
    signal w_crypto_h_stale   : std_logic;
    signal w_crypto_in_proc   : std_logic;

begin

    --------------------------------------------------------------------------
    -- (1) SPLIT_demux : header -> bypass, AAD||PT -> crypto
    --------------------------------------------------------------------------
    u_split : entity work.SPLIT_demux
        generic map (
            DATA_WIDTH   => DATA_WIDTH,
            BYPASS_EN    => BYPASS_EN,
            BYPASS_BYTES => BYPASS_BYTES,
            AAD_BYTES    => AAD_BYTES
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            s_axis_tdata  => s_axis_tdata,
            s_axis_tkeep  => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tready => s_axis_tready,

            m_bypass_axis_tdata  => w_byp_tdata,
            m_bypass_axis_tkeep  => w_byp_tkeep,
            m_bypass_axis_tvalid => w_byp_tvalid,
            m_bypass_axis_tlast  => w_byp_tlast,
            m_bypass_axis_tready => w_byp_tready,

            m_crypto_axis_tdata  => w_cry_tdata,
            m_crypto_axis_tkeep  => w_cry_tkeep,
            m_crypto_axis_tvalid => w_cry_tvalid,
            m_crypto_axis_tlast  => w_cry_tlast,
            m_crypto_axis_tready => w_cry_tready
        );

    --------------------------------------------------------------------------
    -- (2) AXIS_full_skid_buffer : elastic buffer on the bypass path so the
    --     header can wait for the crypto core latency
    --------------------------------------------------------------------------
    gen_bypass_on : if BYPASS_EN generate
        u_skid : entity work.AXIS_full_skid_buffer
            generic map (
                DATA_WIDTH => DATA_WIDTH
            )
            port map (
                i_clk  => i_clk,
                i_rstn => i_rstn,

                s_axis_tdata  => w_byp_tdata,
                s_axis_tkeep  => w_byp_tkeep,
                s_axis_tvalid => w_byp_tvalid,
                s_axis_tlast  => w_byp_tlast,
                s_axis_tready => w_byp_tready,

                m_axis_tdata  => w_skid_tdata,
                m_axis_tkeep  => w_skid_tkeep,
                m_axis_tvalid => w_skid_tvalid,
                m_axis_tlast  => w_skid_tlast,
                m_axis_tready => w_skid_tready
            );
    end generate gen_bypass_on;

    gen_bypass_off : if not BYPASS_EN generate
        -- No bypass stream: the skid buffer is not instantiated. Absorb the (idle)
        -- SPLIT bypass master and hold MERGE's bypass slave inert.
        w_byp_tready  <= '1';
        w_skid_tdata  <= (others => '0');
        w_skid_tkeep  <= (others => '0');
        w_skid_tvalid <= '0';
        w_skid_tlast  <= '0';
    end generate gen_bypass_off;

    --------------------------------------------------------------------------
    -- (3) gcm_enc_glue : AAD||PT in -> AAD||CT||ICV out; drives the crypto
    --     boundary toward AES_algorithm
    --------------------------------------------------------------------------
    u_gcm : entity work.gcm_enc_glue
        generic map (
            AAD_BEATS  => c_AAD_BEATS,
            AAD_BYTES  => AAD_BYTES,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,
            i_tick => '0',

            i_key       => i_key,
            i_key_valid => i_key_valid,
            i_nonce        => i_nonce,
            i_nonce_valid  => i_nonce_valid,

            s_axis_tdata  => w_cry_tdata,
            s_axis_tkeep  => w_cry_tkeep,
            s_axis_tvalid => w_cry_tvalid,
            s_axis_tlast  => w_cry_tlast,
            s_axis_tready => w_cry_tready,

            m_axis_tdata  => w_gcm_tdata,
            m_axis_tkeep  => w_gcm_tkeep,
            m_axis_tvalid => w_gcm_tvalid,
            m_axis_tlast  => w_gcm_tlast,
            m_axis_tready => w_gcm_tready,

            o_ENC_in_proc => o_ENC_in_proc,
            o_TxENC       => o_TxENC,

            o_crypto_key       => w_crypto_key,
            o_crypto_key_valid => w_crypto_key_valid,
            o_crypto_nonce        => w_crypto_IV,
            o_crypto_nonce_valid  => w_crypto_IV_valid,

            m_pt_axis_tdata  => w_pt_tdata,
            m_pt_axis_tkeep  => w_pt_tkeep,
            m_pt_axis_tvalid => w_pt_tvalid,
            m_pt_axis_tlast  => w_pt_tlast,
            m_pt_axis_tready => w_pt_tready,

            s_ct_axis_tdata  => w_ct_tdata,
            s_ct_axis_tkeep  => w_ct_tkeep,
            s_ct_axis_tvalid => w_ct_tvalid,
            s_ct_axis_tlast  => w_ct_tlast,
            s_ct_axis_tready => w_ct_tready,

            i_crypto_H         => w_crypto_H,
            i_crypto_H_valid   => w_crypto_H_valid,
            i_crypto_E_k       => w_crypto_E_k,
            i_crypto_E_k_valid => w_crypto_E_k_valid,
            i_crypto_h_stale   => w_crypto_h_stale,
            i_crypto_in_proc   => w_crypto_in_proc
        );

    --------------------------------------------------------------------------
    -- (4) AES_algorithm : keystream XOR (PT -> CT) + H / E_k(J0) side-band
    --------------------------------------------------------------------------
    u_aes : entity work.AES_algorithm
        generic map (
            AES_BITS     => AES_BITS,
            ROUND_STYLE  => ROUND_STYLE,
            FLOW_STYLE   => FLOW_STYLE,
            WRAPPER_KIND => WRAPPER_KIND,
            NUM_CORES    => NUM_CORES
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            i_key       => w_crypto_key,
            i_key_valid => w_crypto_key_valid,
            i_nonce        => w_crypto_IV,
            i_nonce_valid  => w_crypto_IV_valid,

            s_axis_tdata  => w_pt_tdata,
            s_axis_tkeep  => w_pt_tkeep,
            s_axis_tvalid => w_pt_tvalid,
            s_axis_tlast  => w_pt_tlast,
            s_axis_tready => w_pt_tready,

            m_axis_tdata  => w_ct_tdata,
            m_axis_tkeep  => w_ct_tkeep,
            m_axis_tvalid => w_ct_tvalid,
            m_axis_tlast  => w_ct_tlast,
            m_axis_tready => w_ct_tready,

            o_H       => w_crypto_H,
            o_H_valid => w_crypto_H_valid,

            o_E_k       => w_crypto_E_k,
            o_E_k_valid => w_crypto_E_k_valid,

            o_h_stale            => w_crypto_h_stale,
            o_encryption_in_proc => w_crypto_in_proc
        );

    --------------------------------------------------------------------------
    -- (5) MERGE_mux : header (from skid) || AAD||CT||ICV (from glue) -> one
    --     contiguous output packet
    --------------------------------------------------------------------------
    u_merge : entity work.MERGE_mux
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            BYPASS_EN  => BYPASS_EN
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            s_bypass_axis_tdata  => w_skid_tdata,
            s_bypass_axis_tkeep  => w_skid_tkeep,
            s_bypass_axis_tvalid => w_skid_tvalid,
            s_bypass_axis_tlast  => w_skid_tlast,
            s_bypass_axis_tready => w_skid_tready,

            s_crypto_axis_tdata  => w_gcm_tdata,
            s_crypto_axis_tkeep  => w_gcm_tkeep,
            s_crypto_axis_tvalid => w_gcm_tvalid,
            s_crypto_axis_tlast  => w_gcm_tlast,
            s_crypto_axis_tready => w_gcm_tready,

            m_axis_tdata  => m_axis_tdata,
            m_axis_tkeep  => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tlast  => m_axis_tlast,
            m_axis_tready => m_axis_tready
        );

end architecture;
