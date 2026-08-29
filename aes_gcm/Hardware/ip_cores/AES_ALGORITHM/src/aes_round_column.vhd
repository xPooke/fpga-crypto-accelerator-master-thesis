--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : aes_round_column
-- Module Name   : aes_round_column - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : One column of the AES round computed via the T-table
--                 technique (SubBytes + ShiftRows + MixColumns +
--                 AddRoundKey fused into a single XOR of four 32-bit
--                 table lookups).
--                 The 4 lookups per column happen in parallel on the
--                 SAME T0 BRAM, so the ROM is replicated to supply 4
--                 read ports. A full round issues 16 concurrent reads
--                 (4 columns x 4 bytes); that read count, not the
--                 stored content, is what sets the BRAM instance count.
--                 T0-only: only T0 is stored; T1/T2/T3 are derived
--                 combinationally by byte-rotation of the T0 reads
--                 (zero LUT cost — pure wire reordering). This is a
--                 source-level simplification, NOT a BRAM saving: with
--                 4 distinct tables each would still take 4 reads and
--                 be duplicated anyway, so both schemes end up at the
--                 same number of copies.
--                 Latency: 1 clock cycle (T0 output register).
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std, work.aes_pkg
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 No reset: a reset on the BRAM output register can
--                 prevent BRAM inference; r_t0_* are overwritten on
--                 every clock with i_clk_en='1' anyway.
--                 rom_style attribute is attached to the architecture
--                 SIGNAL w_lcl_t0, NOT the package constant c_T0 —
--                 Vivado ignores rom_style on package constants
--                 (Synth 8-5733).
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.aes_pkg.all;

entity aes_round_column is
    port (
        i_clk       : in  std_logic;
        i_clk_en    : in  std_logic;                     -- pipeline clock enable
        i_a0        : in  std_logic_vector(7 downto 0);
        i_a1        : in  std_logic_vector(7 downto 0);
        i_a2        : in  std_logic_vector(7 downto 0);
        i_a3        : in  std_logic_vector(7 downto 0);
        i_round_key : in  std_logic_vector(31 downto 0);
        o_column    : out std_logic_vector(31 downto 0)
    );
end entity;

architecture rtl of aes_round_column is

    -- Local copy of T0 so the rom_style attribute applies.
    -- T1, T2, T3 are derived by wire rotation on the registered reads.
    signal w_lcl_t0 : t_table_t := c_T0;

    attribute rom_style : string;
    attribute rom_style of w_lcl_t0 : signal is "block";

    -- Four registered T0 reads, one per byte that feeds this column.
    -- These become the BRAM internal output registers.
    signal r_t0_a, r_t0_b, r_t0_c, r_t0_d : std_logic_vector(31 downto 0);
    signal r_round_key                    : std_logic_vector(31 downto 0);

begin

    p_TREG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_clk_en = '1' then
                r_t0_a      <= w_lcl_t0(to_integer(unsigned(i_a0)));
                r_t0_b      <= w_lcl_t0(to_integer(unsigned(i_a1)));
                r_t0_c      <= w_lcl_t0(to_integer(unsigned(i_a2)));
                r_t0_d      <= w_lcl_t0(to_integer(unsigned(i_a3)));
                r_round_key <= i_round_key;
            end if;
        end if;
    end process;

    -- Derive T1/T2/T3 by rotation (pure wire reordering after the register).
    -- Per-bit XOR has 5 inputs -> fits in one LUT6 per output bit.
    o_column <= r_t0_a
           xor rotr_word(r_t0_b, 1)   -- = T1[i_a1]
           xor rotr_word(r_t0_c, 2)   -- = T2[i_a2]
           xor rotr_word(r_t0_d, 3)   -- = T3[i_a3]
           xor r_round_key;

end architecture;
