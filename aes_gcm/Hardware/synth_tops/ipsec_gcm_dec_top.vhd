----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ipsec_gcm_dec_top
-- Module Name   : ipsec_gcm_dec_top - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Synthesis top for the complete decryption IP, the counterpart of
--                 ipsec_gcm_enc_top. It carries the same blocks as top_gcm_dec
--                   SPLIT_demux -> ICV_realign -> gcm_dec_glue + AES_algorithm
--                                -> MERGE_mux
--                 and adds what that top lacks for a timing measurement:
--
--                   * a skid buffer on the s_axis input, ahead of SPLIT_demux
--                   * a skid buffer between SPLIT_demux and ICV_realign
--                   * a skid buffer on the gcm_dec_glue output toward MERGE_mux
--                   * MULT_CYCLES exposed as a generic
--
--                 top_gcm_dec hard-wires MULT_CYCLES to the gcm_dec_glue default of
--                 two, so a single-cycle GHASH cannot be selected there. Rather than
--                 change a verified file, this top is a separate one; the existing
--                 chain is left exactly as the regression suite found it.
--
--                 The bypass skid buffer is the one top_gcm_dec already has.
--
-- Dependencies  : SPLIT_demux, ICV_realign, MERGE_mux, AXIS_full_skid_buffer,
--                 gcm_dec_glue, AES_algorithm and everything below them
--
-- Additional Comments :
--   Active-low reset (i_rstn). Clock port is named i_clk, which the sweep script
--   relies on for create_clock.
--
--   Segment sizes follow IPsec ESP in tunnel mode over Ethernet and IPv4, the same
--   values the encryption top uses:
--     BYPASS_BYTES = 34  Ethernet II header 14 + outer IPv4 header 20
--     AAD_BYTES    = 16  ESP header 8 (SPI 4 + sequence number 4) + explicit IV 8
--   The protected packet ends with the 16-byte ICV, which SPLIT_demux packs onto the
--   crypto stream right behind the ciphertext; ICV_realign gives it back its own
--   TLAST beat, which is what AXIS_DEMUX_dec inside gcm_dec_glue expects.
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ipsec_gcm_dec_top is
    generic (
        DATA_WIDTH   : positive := 128;
        BYPASS_EN    : boolean  := true;
        BYPASS_BYTES : positive := 34;        -- Ethernet 14 + outer IPv4 20
        AAD_BYTES    : positive := 16;        -- ESP header 8 + explicit IV 8
        MULT_CYCLES  : integer  := 1;         -- GHASH multiply timing: 1 or 2 cycles
        AES_BITS     : integer  := 256;
        ROUND_STYLE  : string   := "LUT";     -- "BRAM" or "LUT"
        FLOW_STYLE   : string   := "GLOBAL";  -- "GLOBAL" or "PER_STAGE"
        WRAPPER_KIND : string   := "MULTICORE";
        NUM_CORES    : integer  := 15         -- N_r + 1 gives one block per clock
    );
    port (
        i_clk  : in  std_logic;
        i_rstn : in  std_logic;

        i_key         : in  std_logic_vector(255 downto 0);
        i_key_valid   : in  std_logic;
        i_nonce       : in  std_logic_vector(95 downto 0);
        i_nonce_valid : in  std_logic;

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

        o_auth_ok     : out std_logic;
        o_dec_done    : out std_logic;
        o_DEC_in_proc : out std_logic
    );
end entity;

architecture rtl of ipsec_gcm_dec_top is

    constant c_BUS_BYTES : positive := DATA_WIDTH / 8;
    constant c_AAD_BEATS : natural  := (AAD_BYTES + c_BUS_BYTES - 1) / c_BUS_BYTES;

    -- input skid -> SPLIT_demux
    signal w_in_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_in_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_in_tvalid : std_logic;
    signal w_in_tlast  : std_logic;
    signal w_in_tready : std_logic;

    -- SPLIT_demux -> bypass skid
    signal w_byp_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_byp_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_byp_tvalid : std_logic;
    signal w_byp_tlast  : std_logic;
    signal w_byp_tready : std_logic;

    -- bypass skid -> MERGE_mux
    signal w_skid_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_skid_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_skid_tvalid : std_logic;
    signal w_skid_tlast  : std_logic;
    signal w_skid_tready : std_logic;

    -- SPLIT_demux -> crypto skid  (AAD || CT||ICV packed contiguously)
    signal w_cry_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_cry_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_cry_tvalid : std_logic;
    signal w_cry_tlast  : std_logic;
    signal w_cry_tready : std_logic;

    -- crypto skid -> ICV_realign
    signal w_cskid_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_cskid_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_cskid_tvalid : std_logic;
    signal w_cskid_tlast  : std_logic;
    signal w_cskid_tready : std_logic;

    -- ICV_realign -> gcm_dec_glue  (ICV alone on the TLAST beat)
    signal w_rea_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_rea_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_rea_tvalid : std_logic;
    signal w_rea_tlast  : std_logic;
    signal w_rea_tready : std_logic;

    -- gcm_dec_glue -> output skid  (AAD || PT)
    signal w_gcm_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_gcm_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_gcm_tvalid : std_logic;
    signal w_gcm_tlast  : std_logic;
    signal w_gcm_tready : std_logic;

    -- output skid -> MERGE_mux
    signal w_gout_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_gout_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_gout_tvalid : std_logic;
    signal w_gout_tlast  : std_logic;
    signal w_gout_tready : std_logic;

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
    -- (0) input skid buffer
    --------------------------------------------------------------------------
    u_skid_in : entity work.AXIS_full_skid_buffer
        generic map (DATA_WIDTH => DATA_WIDTH)
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            s_axis_tdata  => s_axis_tdata,
            s_axis_tkeep  => s_axis_tkeep,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tready => s_axis_tready,

            m_axis_tdata  => w_in_tdata,
            m_axis_tkeep  => w_in_tkeep,
            m_axis_tvalid => w_in_tvalid,
            m_axis_tlast  => w_in_tlast,
            m_axis_tready => w_in_tready
        );

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

            s_axis_tdata  => w_in_tdata,
            s_axis_tkeep  => w_in_tkeep,
            s_axis_tvalid => w_in_tvalid,
            s_axis_tlast  => w_in_tlast,
            s_axis_tready => w_in_tready,

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
    -- (2) bypass skid buffer: the header waits here for the crypto latency
    --------------------------------------------------------------------------
    gen_bypass_on : if BYPASS_EN generate
        u_skid_byp : entity work.AXIS_full_skid_buffer
            generic map (DATA_WIDTH => DATA_WIDTH)
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
        w_byp_tready  <= '1';
        w_skid_tdata  <= (others => '0');
        w_skid_tkeep  <= (others => '0');
        w_skid_tvalid <= '0';
        w_skid_tlast  <= '0';
    end generate gen_bypass_off;

    --------------------------------------------------------------------------
    -- (3) crypto skid buffer on the SPLIT_demux -> ICV_realign path
    --------------------------------------------------------------------------
    u_skid_cry : entity work.AXIS_full_skid_buffer
        generic map (DATA_WIDTH => DATA_WIDTH)
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            s_axis_tdata  => w_cry_tdata,
            s_axis_tkeep  => w_cry_tkeep,
            s_axis_tvalid => w_cry_tvalid,
            s_axis_tlast  => w_cry_tlast,
            s_axis_tready => w_cry_tready,

            m_axis_tdata  => w_cskid_tdata,
            m_axis_tkeep  => w_cskid_tkeep,
            m_axis_tvalid => w_cskid_tvalid,
            m_axis_tlast  => w_cskid_tlast,
            m_axis_tready => w_cskid_tready
        );

    --------------------------------------------------------------------------
    -- (4) ICV_realign : put the trailing 16-byte tag back on its own beat
    --------------------------------------------------------------------------
    u_icv : entity work.ICV_realign
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            AAD_BEATS  => c_AAD_BEATS
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            s_axis_tdata  => w_cskid_tdata,
            s_axis_tkeep  => w_cskid_tkeep,
            s_axis_tvalid => w_cskid_tvalid,
            s_axis_tlast  => w_cskid_tlast,
            s_axis_tready => w_cskid_tready,

            m_axis_tdata  => w_rea_tdata,
            m_axis_tkeep  => w_rea_tkeep,
            m_axis_tvalid => w_rea_tvalid,
            m_axis_tlast  => w_rea_tlast,
            m_axis_tready => w_rea_tready
        );

    --------------------------------------------------------------------------
    -- (5) gcm_dec_glue : AAD||CT||ICV in -> AAD||PT out, with tag verification
    --------------------------------------------------------------------------
    u_gcm : entity work.gcm_dec_glue
        generic map (
            AAD_BEATS   => c_AAD_BEATS,
            AAD_BYTES   => AAD_BYTES,
            DATA_WIDTH  => DATA_WIDTH,
            MULT_CYCLES => MULT_CYCLES
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            i_key         => i_key,
            i_key_valid   => i_key_valid,
            i_nonce       => i_nonce,
            i_nonce_valid => i_nonce_valid,

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

            o_crypto_key         => w_crypto_key,
            o_crypto_key_valid   => w_crypto_key_valid,
            o_crypto_nonce       => w_crypto_IV,
            o_crypto_nonce_valid => w_crypto_IV_valid,

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
    -- (6) AES_algorithm : keystream XOR (CT -> PT) + H / E_k(J0) side-band
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

            i_key         => w_crypto_key,
            i_key_valid   => w_crypto_key_valid,
            i_nonce       => w_crypto_IV,
            i_nonce_valid => w_crypto_IV_valid,

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
    -- (7) output skid buffer on the glue -> MERGE_mux path
    --------------------------------------------------------------------------
    u_skid_out : entity work.AXIS_full_skid_buffer
        generic map (DATA_WIDTH => DATA_WIDTH)
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,

            s_axis_tdata  => w_gcm_tdata,
            s_axis_tkeep  => w_gcm_tkeep,
            s_axis_tvalid => w_gcm_tvalid,
            s_axis_tlast  => w_gcm_tlast,
            s_axis_tready => w_gcm_tready,

            m_axis_tdata  => w_gout_tdata,
            m_axis_tkeep  => w_gout_tkeep,
            m_axis_tvalid => w_gout_tvalid,
            m_axis_tlast  => w_gout_tlast,
            m_axis_tready => w_gout_tready
        );

    --------------------------------------------------------------------------
    -- (8) MERGE_mux : header || AAD||PT -> one contiguous plain packet
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

            s_crypto_axis_tdata  => w_gout_tdata,
            s_crypto_axis_tkeep  => w_gout_tkeep,
            s_crypto_axis_tvalid => w_gout_tvalid,
            s_crypto_axis_tlast  => w_gout_tlast,
            s_crypto_axis_tready => w_gout_tready,

            m_axis_tdata  => m_axis_tdata,
            m_axis_tkeep  => m_axis_tkeep,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tlast  => m_axis_tlast,
            m_axis_tready => m_axis_tready
        );

end architecture;
