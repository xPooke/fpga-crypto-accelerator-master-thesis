----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : top_gcm_dec
-- Module Name   : top_gcm_dec - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Full AES-GCM decryption datapath - 6 IP cores wired together.
--
--   s_axis (bypass || AAD || CT || ICV)
--        |
--   SPLIT_demux ---- m_bypass ----> AXIS_full_skid_buffer -------------+
--        |                                                             |
--        +---- m_crypto (AAD || CT||ICV packed) ---> ICV_realign       |
--                                                        |             |
--                     (tag put back on its own beat)     v             |
--                                                   gcm_dec_glue       |
--                                                     ^   |            |
--                        crypto boundary (CT/PT +     | H/E_k)         |
--                                                     |   v            v
--                                                 AES_algorithm    MERGE_mux
--                                                                      |
--                                                        m_axis (bypass || AAD || PT)
--
--   Cores: SPLIT_demux, AXIS_full_skid_buffer, ICV_realign, gcm_dec_glue,
--          AES_algorithm, MERGE_mux.
--
-- Dependencies  : work.SPLIT_demux, work.MERGE_mux, work.AXIS_full_skid_buffer,
--                 work.gcm_dec_glue, work.AES_algorithm
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

entity top_gcm_dec is
    generic (
        DATA_WIDTH   : positive := 128;
        BYPASS_EN    : boolean  := true;      -- true = bypass segment present; false = disabled
        BYPASS_BYTES : positive := 50;        -- bypass segment bytes (used only when BYPASS_EN)
        AAD_BYTES    : positive := 20;        -- AAD bytes
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

        -- AXIS slave: protected packet  bypass || AAD || CT || ICV
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXIS master: recovered plain packet  bypass || AAD || PT
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic;

        -- Side-band
        o_auth_ok     : out std_logic;
        o_dec_done    : out std_logic;
        o_DEC_in_proc : out std_logic
    );
end entity;

architecture rtl of top_gcm_dec is

    constant c_BUS_BYTES : positive := DATA_WIDTH / 8;
    constant c_AAD_BEATS : natural  := (AAD_BYTES + c_BUS_BYTES - 1) / c_BUS_BYTES;

    -- SPLIT_demux -> skid (bypass path)
    signal w_byp_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_byp_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_byp_tvalid : std_logic;
    signal w_byp_tlast  : std_logic;
    signal w_byp_tready : std_logic;

    -- skid -> MERGE_mux
    signal w_skid_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_skid_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_skid_tvalid : std_logic;
    signal w_skid_tlast  : std_logic;
    signal w_skid_tready : std_logic;

    -- SPLIT_demux -> ICV_realign  (AAD || CT||ICV packed contiguously)
    signal w_cry_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_cry_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_cry_tvalid : std_logic;
    signal w_cry_tlast  : std_logic;
    signal w_cry_tready : std_logic;

    -- ICV_realign -> gcm_dec_glue  (AAD || CT || ICV, ICV alone on the TLAST beat)
    signal w_rea_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_rea_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_rea_tvalid : std_logic;
    signal w_rea_tlast  : std_logic;
    signal w_rea_tready : std_logic;

    -- gcm_dec_glue -> MERGE_mux  (AAD || PT)
    signal w_gcm_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_gcm_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_gcm_tvalid : std_logic;
    signal w_gcm_tlast  : std_logic;
    signal w_gcm_tready : std_logic;

    -- crypto boundary: glue -> AES (CT)
    signal w_ct_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_ct_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_ct_tvalid : std_logic;
    signal w_ct_tlast  : std_logic;
    signal w_ct_tready : std_logic;

    -- crypto boundary: AES -> glue (PT)
    signal w_pt_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_pt_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_pt_tvalid : std_logic;
    signal w_pt_tlast  : std_logic;
    signal w_pt_tready : std_logic;

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
    -- (1) SPLIT_demux : header -> bypass, AAD||CT||ICV -> crypto
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
    -- (2) AXIS_full_skid_buffer : bypass-path elastic buffer
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
    -- (3a) ICV_realign : put the trailing 16-byte tag back on its OWN beat,
    --      which is what AXIS_DEMUX_dec inside gcm_dec_glue requires
    --      (TLAST beat = ICV beat).  SPLIT_demux packs CT||ICV contiguously.
    --------------------------------------------------------------------------
    u_icv : entity work.ICV_realign
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            AAD_BEATS  => c_AAD_BEATS
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            s_axis_tdata  => w_cry_tdata,
            s_axis_tkeep  => w_cry_tkeep,
            s_axis_tvalid => w_cry_tvalid,
            s_axis_tlast  => w_cry_tlast,
            s_axis_tready => w_cry_tready,

            m_axis_tdata  => w_rea_tdata,
            m_axis_tkeep  => w_rea_tkeep,
            m_axis_tvalid => w_rea_tvalid,
            m_axis_tlast  => w_rea_tlast,
            m_axis_tready => w_rea_tready
        );

    --------------------------------------------------------------------------
    -- (3b) gcm_dec_glue : AAD||CT||ICV in -> AAD||PT out (+ tag verify)
    --------------------------------------------------------------------------
    u_gcm : entity work.gcm_dec_glue
        generic map (
            AAD_BEATS  => c_AAD_BEATS,
            AAD_BYTES  => AAD_BYTES,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            i_key       => i_key,
            i_key_valid => i_key_valid,
            i_nonce        => i_nonce,
            i_nonce_valid  => i_nonce_valid,

            s_axis_tdata  => w_rea_tdata,
            s_axis_tkeep  => w_rea_tkeep,
            s_axis_tvalid => w_rea_tvalid,
            s_axis_tlast  => w_rea_tlast,
            s_axis_tready => w_rea_tready,

            m_axis_tdata  => w_gcm_tdata,
            m_axis_tkeep  => w_gcm_tkeep,
            m_axis_tvalid => w_gcm_tvalid,
            m_axis_tlast  => w_gcm_tlast,
            m_axis_tready => w_gcm_tready,

            o_auth_ok     => o_auth_ok,
            o_dec_done    => o_dec_done,
            o_DEC_in_proc => o_DEC_in_proc,

            o_crypto_key       => w_crypto_key,
            o_crypto_key_valid => w_crypto_key_valid,
            o_crypto_nonce        => w_crypto_IV,
            o_crypto_nonce_valid  => w_crypto_IV_valid,

            m_ct_axis_tdata  => w_ct_tdata,
            m_ct_axis_tkeep  => w_ct_tkeep,
            m_ct_axis_tvalid => w_ct_tvalid,
            m_ct_axis_tlast  => w_ct_tlast,
            m_ct_axis_tready => w_ct_tready,

            s_pt_axis_tdata  => w_pt_tdata,
            s_pt_axis_tkeep  => w_pt_tkeep,
            s_pt_axis_tvalid => w_pt_tvalid,
            s_pt_axis_tlast  => w_pt_tlast,
            s_pt_axis_tready => w_pt_tready,

            i_crypto_H         => w_crypto_H,
            i_crypto_H_valid   => w_crypto_H_valid,
            i_crypto_E_k       => w_crypto_E_k,
            i_crypto_E_k_valid => w_crypto_E_k_valid,
            i_crypto_h_stale   => w_crypto_h_stale,
            i_crypto_in_proc   => w_crypto_in_proc
        );

    --------------------------------------------------------------------------
    -- (4) AES_algorithm : keystream XOR (CT -> PT) + H / E_k(J0) side-band
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

            s_axis_tdata  => w_ct_tdata,
            s_axis_tkeep  => w_ct_tkeep,
            s_axis_tvalid => w_ct_tvalid,
            s_axis_tlast  => w_ct_tlast,
            s_axis_tready => w_ct_tready,

            m_axis_tdata  => w_pt_tdata,
            m_axis_tkeep  => w_pt_tkeep,
            m_axis_tvalid => w_pt_tvalid,
            m_axis_tlast  => w_pt_tlast,
            m_axis_tready => w_pt_tready,

            o_H       => w_crypto_H,
            o_H_valid => w_crypto_H_valid,

            o_E_k       => w_crypto_E_k,
            o_E_k_valid => w_crypto_E_k_valid,

            o_h_stale            => w_crypto_h_stale,
            o_encryption_in_proc => w_crypto_in_proc
        );

    --------------------------------------------------------------------------
    -- (5) MERGE_mux : header (skid) || AAD||PT (glue) -> plain packet
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
