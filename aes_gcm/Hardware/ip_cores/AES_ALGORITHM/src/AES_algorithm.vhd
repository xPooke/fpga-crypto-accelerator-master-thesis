----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : AES_algorithm
-- Module Name   : AES_algorithm - rtl
-- Project Name  : AES-128/256 + GCM (master thesis)
-- Tool Version  : Vivado 2025.1
--
-- Description   : Top for the AES crypto algorithm (the dynamic half of
--                 the static/dynamic GCM split). Thin selector around
--                 AES_pipelined_wrapper (UNROLLED) or AES_multicore_wrapper
--                 (MULTICORE) via WRAPPER_KIND; every port passes straight
--                 through.
--
-- Dependencies  : work.AES_pipelined_wrapper, work.AES_multicore_wrapper
--
-- Revision      :
--   0.01 - June 2026 - File Created
--
-- Additional Comments :
--   Generics are resolved at synthesis; WRAPPER_KIND picks the variant.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity AES_algorithm is
    generic (
        AES_BITS     : integer := 128;       -- 128 or 256
        ROUND_STYLE  : string  := "BRAM";    -- "BRAM" or "LUT"
        FLOW_STYLE   : string  := "GLOBAL";  -- "GLOBAL" or "PER_STAGE" (UNROLLED only)
        WRAPPER_KIND : string  := "UNROLLED";-- "UNROLLED" or "MULTICORE"
        NUM_CORES    : integer := 4          -- MULTICORE only
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;                          -- active low

        -- Key + nonce config (256-bit key; LSB AES_BITS bits used)
        i_key         : in  std_logic_vector(255 downto 0);
        i_key_valid   : in  std_logic;
        i_nonce       : in  std_logic_vector(95 downto 0);
        i_nonce_valid : in  std_logic;

        -- AXIS slave (data into the keystream XOR)
        s_axis_tdata  : in  std_logic_vector(127 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tkeep  : in  std_logic_vector(15 downto 0);

        -- AXIS master (XOR-ed data out)
        m_axis_tdata  : out std_logic_vector(127 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tkeep  : out std_logic_vector(15 downto 0);

        -- Side-band: H (for GHASH)
        o_H           : out std_logic_vector(127 downto 0);
        o_H_valid     : out std_logic;

        -- Side-band: E_K(J0) (tag mask)
        o_E_k         : out std_logic_vector(127 downto 0);
        o_E_k_valid   : out std_logic;

        -- Side-band: '1' while the latched H is stale (key change pending its
        -- recompute); a downstream GHASH gate holds a packet until H is fresh
        o_h_stale     : out std_logic;

        -- Side-band: '1' while the algorithm is processing
        o_encryption_in_proc : out std_logic
    );
end entity;

architecture rtl of AES_algorithm is

begin

    assert WRAPPER_KIND = "UNROLLED" or WRAPPER_KIND = "MULTICORE"
        report "AES_algorithm: WRAPPER_KIND must be ""UNROLLED"" or ""MULTICORE"""
        severity failure;

    --------------------------------------------------------------------------
    -- UNROLLED: one fully pipelined core (1 block/clk steady state)
    --------------------------------------------------------------------------
    gen_unrolled : if WRAPPER_KIND = "UNROLLED" generate
        u_aes : entity work.AES_pipelined_wrapper
            generic map (
                AES_BITS    => AES_BITS,
                ROUND_STYLE => ROUND_STYLE,
                FLOW_STYLE  => FLOW_STYLE
            )
            port map (
                i_clk         => i_clk,
                i_rstn        => i_rstn,
                i_key         => i_key,
                i_key_valid   => i_key_valid,
                i_nonce       => i_nonce,
                i_nonce_valid => i_nonce_valid,
                s_axis_tdata  => s_axis_tdata,
                s_axis_tvalid => s_axis_tvalid,
                s_axis_tready => s_axis_tready,
                s_axis_tlast  => s_axis_tlast,
                s_axis_tkeep  => s_axis_tkeep,
                m_axis_tdata  => m_axis_tdata,
                m_axis_tvalid => m_axis_tvalid,
                m_axis_tready => m_axis_tready,
                m_axis_tlast  => m_axis_tlast,
                m_axis_tkeep  => m_axis_tkeep,
                o_H           => o_H,
                o_H_valid     => o_H_valid,
                o_E_k         => o_E_k,
                o_E_k_valid   => o_E_k_valid,
                o_h_stale     => o_h_stale,
                o_encryption_in_proc => o_encryption_in_proc
            );
    end generate gen_unrolled;

    --------------------------------------------------------------------------
    -- MULTICORE: NUM_CORES iterative cores in round-robin
    --------------------------------------------------------------------------
    gen_multicore : if WRAPPER_KIND = "MULTICORE" generate
        u_aes : entity work.AES_multicore_wrapper
            generic map (
                AES_BITS    => AES_BITS,
                ROUND_STYLE => ROUND_STYLE,
                NUM_CORES   => NUM_CORES
            )
            port map (
                i_clk         => i_clk,
                i_rstn        => i_rstn,
                i_key         => i_key,
                i_key_valid   => i_key_valid,
                i_nonce       => i_nonce,
                i_nonce_valid => i_nonce_valid,
                s_axis_tdata  => s_axis_tdata,
                s_axis_tvalid => s_axis_tvalid,
                s_axis_tready => s_axis_tready,
                s_axis_tlast  => s_axis_tlast,
                s_axis_tkeep  => s_axis_tkeep,
                m_axis_tdata  => m_axis_tdata,
                m_axis_tvalid => m_axis_tvalid,
                m_axis_tready => m_axis_tready,
                m_axis_tlast  => m_axis_tlast,
                m_axis_tkeep  => m_axis_tkeep,
                o_H           => o_H,
                o_H_valid     => o_H_valid,
                o_E_k         => o_E_k,
                o_E_k_valid   => o_E_k_valid,
                o_h_stale     => o_h_stale,
                o_encryption_in_proc => o_encryption_in_proc
            );
    end generate gen_multicore;

end architecture;
