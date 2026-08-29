----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ipsec_gcm_enc_top
-- Module Name   : ipsec_gcm_enc_top - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Synthesis top for the complete encryption IP: frame handling plus
--                 the crypto core, the shape that would be dropped into a real
--                 system. It carries the same five blocks as top_gcm_enc
--                   SPLIT_demux -> gcm_enc_glue + AES_algorithm -> MERGE_mux
--                 and adds what that top lacks for a timing measurement:
--
--                   * a skid buffer on the s_axis input, ahead of SPLIT_demux
--                   * a skid buffer on the gcm_enc_glue output toward MERGE_mux
--                   * MULT_CYCLES exposed as a generic
--
--                 top_gcm_enc hard-wires MULT_CYCLES to the gcm_enc_glue default of
--                 two, so a single-cycle GHASH cannot be selected there. Rather than
--                 change a verified file, this top is a separate one; the existing
--                 chain is left exactly as the regression suite found it.
--
--                 The bypass skid buffer is the one top_gcm_enc already has.
--
-- Dependencies  : SPLIT_demux, MERGE_mux, AXIS_full_skid_buffer, gcm_enc_glue,
--                 AES_algorithm and everything below them
--
-- Additional Comments :
--   Active-low reset (i_rstn). Clock port is named i_clk, which the sweep script
--   relies on for create_clock.
--
--   Segment sizes are driven by IPsec ESP in tunnel mode over Ethernet and IPv4:
--     BYPASS_BYTES = 34  Ethernet II header 14 + outer IPv4 header 20
--     AAD_BYTES    = 16  ESP header 8 (SPI 4 + sequence number 4) + explicit IV 8
--   RFC 4106 authenticates only SPI||SeqNum, so covering the IV as well is a
--   superset. It keeps the IV inside the segment that reaches the output untouched,
--   which is what this datapath needs, and both segment ends stay off the bus word
--   boundary, the case SPLIT_demux is verified for.
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ipsec_gcm_enc_top is
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

        o_ENC_in_proc : out std_logic;
        o_TxENC       : out std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of ipsec_gcm_enc_top is

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

    -- SPLIT_demux -> gcm_enc_glue  (AAD || PT)
    signal w_cry_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_cry_tkeep  : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_cry_tvalid : std_logic;
    signal w_cry_tlast  : std_logic;
    signal w_cry_tready : std_logic;

    -- gcm_enc_glue -> output skid  (AAD || CT || ICV)
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
    -- (0) input skid buffer: registers the port side so the combinational
    --     tready of SPLIT_demux does not reach the module boundary
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
    -- (3) gcm_enc_glue : AAD||PT in -> AAD||CT||ICV out
    --------------------------------------------------------------------------
    u_gcm : entity work.gcm_enc_glue
        generic map (
            AAD_BEATS   => c_AAD_BEATS,
            AAD_BYTES   => AAD_BYTES,
            DATA_WIDTH  => DATA_WIDTH,
            MULT_CYCLES => MULT_CYCLES
        )
        port map (
            i_clk  => i_clk,
            i_rstn => i_rstn,
            i_tick => '0',

            i_key         => i_key,
            i_key_valid   => i_key_valid,
            i_nonce       => i_nonce,
            i_nonce_valid => i_nonce_valid,

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

            o_crypto_key         => w_crypto_key,
            o_crypto_key_valid   => w_crypto_key_valid,
            o_crypto_nonce       => w_crypto_IV,
            o_crypto_nonce_valid => w_crypto_IV_valid,

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

            i_key         => w_crypto_key,
            i_key_valid   => w_crypto_key_valid,
            i_nonce       => w_crypto_IV,
            i_nonce_valid => w_crypto_IV_valid,

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
    -- (5) output skid buffer on the glue -> MERGE_mux path
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
    -- (6) MERGE_mux : header || AAD||CT||ICV -> one contiguous output packet
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
