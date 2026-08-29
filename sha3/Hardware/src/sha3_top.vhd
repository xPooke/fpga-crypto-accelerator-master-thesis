----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : January 2026
-- Design Name   : sha3_top
-- Module Name   : sha3_top - rtl
-- Project Name  : SHA3-224/256/384/512 + SHAKE128/256 accelerator (master thesis)
-- Tool Version  : Vivado 2025.1
--
-- Description   : SHA-3 / SHAKE hash engine top: sha3_input_buffer (block
--                 assembly + padding) -> keccak_sponge (absorb + Keccak-f[1600]
--                 + squeeze) -> sha3_output_buffer (serialization). ALGORITHM
--                 picks SHA3 (fixed digest, pad 0x06), SHAKE XOF (SHAKE_BITS
--                 of output, pad 0x1F, multi-chunk squeeze) or CSHAKE
--                 (pad 0x04; the SP 800-185 N/S prefix block -- and the key
--                 block + right_encode(L) for KMAC -- arrive as ordinary
--                 message data, formatted by software). All three stages run
--                 in parallel, coupled only by valid/ready handshakes.
--
-- Dependencies  : work.keccak_pkg, work.sha3_input_buffer,
--                 work.keccak_sponge, work.sha3_output_buffer
--
-- Revision      :
--   0.01 - January 2026 - File Created
--
-- Additional Comments :
--   Active-low reset. Geometry (FIPS 202): SHA3-d -> rate = 1600 - 2d;
--   SHAKE128 -> rate 1344, SHAKE256 -> rate 1088. DATA_WIDTH must divide
--   the rate and the output size (rejected at elaboration) -- in practice
--   8/16/32/64, at most 32 for SHA3-224. SHAKE_BITS is any multiple of
--   DATA_WIDTH (e.g. 8192); resources do not grow with it, only latency
--   (one extra 24-round permutation per rate-sized chunk).
--   ALGORITHM = CSHAKE assumes a non-empty prefix block. SP 800-185 defines
--   cSHAKE with empty N and S as plain SHAKE, which needs pad byte 1F rather
--   than 04; this mode only serves KMAC, whose N is fixed by the standard.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.keccak_pkg.all;

entity sha3_top is
    generic (
        ALGORITHM        : string  := "SHA3";   -- "SHA3", "SHAKE" or "CSHAKE"
        SHA3_VERSION     : string  := "256";    -- "224", "256", "384" or "512" (ALGORITHM = SHA3)
        SHAKE_VERSION    : string  := "256";    -- "128" or "256"               (ALGORITHM = SHAKE/CSHAKE)
        SHAKE_BITS       : integer := 1024;     -- output size in bits          (ALGORITHM = SHAKE/CSHAKE)
        DATA_WIDTH       : integer := 32;       -- AXIS data width
        ROUNDS_PER_CYCLE : integer := 1         -- Keccak rounds per clock (divisor of 24)
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;                                     -- active low
        i_config      : in  std_logic;                                     -- enable

        -- AXI-Stream slave (message in)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH / 8 - 1 downto 0);

        -- AXI-Stream master (digest / XOF output)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity;

architecture rtl of sha3_top is

    ----------------------------------------------------------------------------
    -- Geometry from ALGORITHM + version generics (FIPS 202)
    ----------------------------------------------------------------------------
    function digest_bits(ver : string) return integer is
    begin
        if    ver = "224" then return 224;
        elsif ver = "256" then return 256;
        elsif ver = "384" then return 384;
        else                   return 512;
        end if;
    end function;

    function rate_bits_f return integer is
    begin
        if ALGORITHM = "SHAKE" or ALGORITHM = "CSHAKE" then
            if SHAKE_VERSION = "128" then
                return 1344;  -- capacity 256
            else
                return 1088;  -- capacity 512
            end if;
        else
            return c_STATE_BITS - 2 * digest_bits(SHA3_VERSION);  -- r = 1600 - 2d
        end if;
    end function;

    function out_bits_f return integer is
    begin
        if ALGORITHM = "SHAKE" or ALGORITHM = "CSHAKE" then
            return SHAKE_BITS;
        else
            return digest_bits(SHA3_VERSION);
        end if;
    end function;

    function pad_byte_f return std_logic_vector is
    begin
        if ALGORITHM = "SHAKE" then
            return std_logic_vector'(x"1F");  -- domain 1111 + first pad bit
        elsif ALGORITHM = "CSHAKE" then
            return std_logic_vector'(x"04");  -- domain 00 + first pad bit (SP 800-185)
        else
            return std_logic_vector'(x"06");  -- domain 01 + first pad bit
        end if;
    end function;

    constant c_RATE_BITS  : integer := rate_bits_f;
    constant c_RATE_WORDS : integer := c_RATE_BITS / DATA_WIDTH;
    constant c_OUT_BITS   : integer := out_bits_f;
    constant c_CHUNK_BITS : integer := imin(c_OUT_BITS, c_RATE_BITS);  -- squeeze chunk size
    constant c_PAD_BYTE   : std_logic_vector(7 downto 0) := pad_byte_f;

    ----------------------------------------------------------------------------
    -- Input buffer -> sponge
    ----------------------------------------------------------------------------
    signal w_block       : std_logic_vector(c_RATE_WORDS * DATA_WIDTH - 1 downto 0);
    signal w_block_valid : std_logic;
    signal w_block_last  : std_logic;
    signal w_block_ready : std_logic;

    ----------------------------------------------------------------------------
    -- Sponge -> output buffer
    ----------------------------------------------------------------------------
    signal w_chunk       : std_logic_vector(c_CHUNK_BITS - 1 downto 0);
    signal w_chunk_valid : std_logic;
    signal w_chunk_ready : std_logic;

begin

    assert ALGORITHM = "SHA3" or ALGORITHM = "SHAKE" or ALGORITHM = "CSHAKE"
        report "sha3_top: ALGORITHM must be ""SHA3"", ""SHAKE"" or ""CSHAKE"""
        severity failure;

    assert ALGORITHM /= "SHA3"
        or SHA3_VERSION = "224" or SHA3_VERSION = "256"
        or SHA3_VERSION = "384" or SHA3_VERSION = "512"
        report "sha3_top: SHA3_VERSION must be ""224"", ""256"", ""384"" or ""512"""
        severity failure;

    assert (ALGORITHM /= "SHAKE" and ALGORITHM /= "CSHAKE")
        or SHAKE_VERSION = "128" or SHAKE_VERSION = "256"
        report "sha3_top: SHAKE_VERSION must be ""128"" or ""256"""
        severity failure;

    assert c_RATE_BITS mod DATA_WIDTH = 0
        report "sha3_top: DATA_WIDTH must divide the rate ("
             & integer'image(c_RATE_BITS) & " bits)"
        severity failure;

    assert c_OUT_BITS mod DATA_WIDTH = 0
        report "sha3_top: DATA_WIDTH must divide the output size ("
             & integer'image(c_OUT_BITS)
             & " bits) -- e.g. SHA3-224 with DATA_WIDTH=64 is unsupported"
        severity failure;

    assert c_OUT_BITS >= DATA_WIDTH
        report "sha3_top: output size must be at least one DATA_WIDTH word"
        severity failure;

    ----------------------------------------------------------------------------
    -- Input buffer: block assembly + SHA-3/SHAKE padding
    ----------------------------------------------------------------------------
    u_input_buffer : entity work.sha3_input_buffer
        generic map (
            RATE_WORDS => c_RATE_WORDS,
            DATA_WIDTH => DATA_WIDTH,
            PAD_BYTE   => c_PAD_BYTE
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,
            i_config      => i_config,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tkeep  => s_axis_tkeep,
            o_block       => w_block,
            o_block_valid => w_block_valid,
            i_block_ready => w_block_ready,
            o_block_last  => w_block_last
        );

    ----------------------------------------------------------------------------
    -- Sponge: absorb + Keccak-f[1600] permutation + squeeze
    ----------------------------------------------------------------------------
    u_sponge : entity work.keccak_sponge
        generic map (
            RATE_WORDS       => c_RATE_WORDS,
            DATA_WIDTH       => DATA_WIDTH,
            OUT_BITS         => c_OUT_BITS,
            ROUNDS_PER_CYCLE => ROUNDS_PER_CYCLE
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,
            i_block       => w_block,
            i_block_valid => w_block_valid,
            i_block_last  => w_block_last,
            o_block_ready => w_block_ready,
            o_chunk       => w_chunk,
            o_chunk_valid => w_chunk_valid,
            i_chunk_ready => w_chunk_ready
        );

    ----------------------------------------------------------------------------
    -- Output buffer: chunk serialization (double-buffered against the sponge)
    ----------------------------------------------------------------------------
    u_output_buffer : entity work.sha3_output_buffer
        generic map (
            DATA_WIDTH => DATA_WIDTH,
            OUT_BITS   => c_OUT_BITS,
            CHUNK_BITS => c_CHUNK_BITS
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,
            i_chunk       => w_chunk,
            i_chunk_valid => w_chunk_valid,
            o_chunk_ready => w_chunk_ready,
            m_axis_tdata  => m_axis_tdata,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready,
            m_axis_tlast  => m_axis_tlast
        );

end architecture;
