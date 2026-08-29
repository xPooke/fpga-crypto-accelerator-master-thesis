--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : GHASH
-- Module Name   : GHASH - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : GHASH accumulator for GCM: on every valid input block X_i
--                 the accumulator advances as Y <- (Y XOR X_i) * H over
--                 GF(2^128), H being the hash sub-key H = AES_K(0^128).
--                 Thin selector around the two multiplier timings, chosen by
--                 MULT_CYCLES; every port passes straight through:
--
--                   1 -> GHASH_single    : the whole multiply is one
--                                          combinational cone -- one block
--                                          per cycle, longest critical path
--                   2 -> GHASH_pipelined : the multiply is split across two
--                                          cycles by a partial-product
--                                          register bank -- one block every
--                                          other cycle, shorter path
--
--                 GHASH_wrapper reads the same generic and throttles its
--                 feed accordingly, so the choice is invisible upstream.
-- Dependencies  : work.GHASH_single, work.GHASH_pipelined
-- Additional Comments :
--                 Active-low reset. i_init clears Y (once before the first
--                 block of a packet); o_Y_valid pulses one cycle after the
--                 packet's final block has been absorbed. Generics are
--                 resolved at synthesis.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity GHASH is
    generic (
        MULT_CYCLES : integer := 2                       -- 1 or 2 clock cycles per GF(2^128) multiply
    );
    port (
        i_clk     : in  std_logic;
        i_rstn    : in  std_logic;
        i_init    : in  std_logic;                       -- sync clear; assert before each new packet
        i_valid   : in  std_logic;                       -- 1-cycle pulse: i_X holds a valid AAD/CT block
        i_last    : in  std_logic;                       -- assert with i_valid on the packet's final block
        i_X       : in  std_logic_vector(127 downto 0);  -- AAD/CT block, NIST byte order
        i_H       : in  std_logic_vector(127 downto 0);  -- hash sub-key H = AES_K(0^128), NIST order
        o_Y       : out std_logic_vector(127 downto 0);  -- accumulated GHASH register
        o_Y_valid : out std_logic                        -- pulses one cycle after the final absorbed beat
    );
end entity;

architecture rtl of GHASH is

begin

    assert MULT_CYCLES = 1 or MULT_CYCLES = 2
        report "GHASH: MULT_CYCLES must be 1 or 2"
        severity failure;

    ----------------------------------------------------------------------------
    -- One block per cycle: the multiplier is a single combinational cone
    ----------------------------------------------------------------------------
    gen_single : if MULT_CYCLES = 1 generate
        u_ghash : entity work.GHASH_single
            port map (
                i_clk     => i_clk,
                i_rstn    => i_rstn,
                i_init    => i_init,
                i_valid   => i_valid,
                i_last    => i_last,
                i_X       => i_X,
                i_H       => i_H,
                o_Y       => o_Y,
                o_Y_valid => o_Y_valid
            );
    end generate gen_single;

    ----------------------------------------------------------------------------
    -- One block every other cycle: the multiply is split in two stages
    ----------------------------------------------------------------------------
    gen_pipelined : if MULT_CYCLES = 2 generate
        u_ghash : entity work.GHASH_pipelined
            port map (
                i_clk     => i_clk,
                i_rstn    => i_rstn,
                i_init    => i_init,
                i_valid   => i_valid,
                i_last    => i_last,
                i_X       => i_X,
                i_H       => i_H,
                o_Y       => o_Y,
                o_Y_valid => o_Y_valid
            );
    end generate gen_pipelined;

end architecture;
