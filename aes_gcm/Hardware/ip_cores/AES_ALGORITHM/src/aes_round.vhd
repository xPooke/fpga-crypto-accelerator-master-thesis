--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : aes_round
-- Module Name   : aes_round - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : One AES encryption round, 1 clock cycle latency.
--                 ROUND_STYLE selects the implementation:
--                   "BRAM" : 4x aes_round_column instances using
--                            T-table lookups (ShiftRows baked into
--                            byte indexing)
--                   "LUT"  : single registered process applying the
--                            aes_pkg functions sub_bytes / shift_rows /
--                            mix_columns / add_round_key in sequence
--                 Both modes share the same port interface and produce
--                 identical functional output (drop-in replacement).
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std, work.aes_pkg,
--                 work.aes_round_column (BRAM mode only)
-- Revision      :
--   0.01 - May 2026 - File created
--   0.02 - Aug 2026 - Combinational SubBytes tap exported (o_sub_bytes) so
--                     the rolled core's last round can reuse it in LUT mode
-- Additional Comments :
--                 Byte / state convention: byte 0 = i_state(127..120),
--                 byte 15 = i_state(7..0).
--                 Invalid ROUND_STYLE is rejected at elaboration via
--                 an assert with severity failure.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.aes_pkg.all;

entity aes_round is
    generic (
        ROUND_STYLE : string := "BRAM"   -- "BRAM" or "LUT"
    );
    port (
        i_clk       : in  std_logic;
        i_clk_en    : in  std_logic;                              -- pipeline clock enable
        i_state     : in  std_logic_vector(127 downto 0);
        i_round_key : in  std_logic_vector(127 downto 0);
        o_state     : out std_logic_vector(127 downto 0);
        o_sub_bytes : out std_logic_vector(127 downto 0)   -- combinational SubBytes(i_state) tap (LUT mode; zeros in BRAM mode)
    );
end entity;

architecture rtl of aes_round is
begin

    -- Reject invalid generic values at elaboration.
    assert (ROUND_STYLE = "BRAM") or (ROUND_STYLE = "LUT")
        report "aes_round: ROUND_STYLE must be ""BRAM"" or ""LUT"""
        severity failure;

    ---------------------------------------------------------------------------
    -- BRAM mode: 4 aes_round_column with T-tables.
    -- ShiftRows is woven into the byte selection for each column.
    ---------------------------------------------------------------------------
    gen_bram : if ROUND_STYLE = "BRAM" generate
        -- Byte slices of i_state
        signal w_b0,  w_b1,  w_b2,  w_b3  : std_logic_vector(7 downto 0);
        signal w_b4,  w_b5,  w_b6,  w_b7  : std_logic_vector(7 downto 0);
        signal w_b8,  w_b9,  w_b10, w_b11 : std_logic_vector(7 downto 0);
        signal w_b12, w_b13, w_b14, w_b15 : std_logic_vector(7 downto 0);
        -- Column outputs from aes_round_column instances
        signal w_col0, w_col1, w_col2, w_col3 : std_logic_vector(31 downto 0);
    begin
        w_b0  <= i_state(127 downto 120);
        w_b1  <= i_state(119 downto 112);
        w_b2  <= i_state(111 downto 104);
        w_b3  <= i_state(103 downto 96);
        w_b4  <= i_state(95  downto 88);
        w_b5  <= i_state(87  downto 80);
        w_b6  <= i_state(79  downto 72);
        w_b7  <= i_state(71  downto 64);
        w_b8  <= i_state(63  downto 56);
        w_b9  <= i_state(55  downto 48);
        w_b10 <= i_state(47  downto 40);
        w_b11 <= i_state(39  downto 32);
        w_b12 <= i_state(31  downto 24);
        w_b13 <= i_state(23  downto 16);
        w_b14 <= i_state(15  downto 8);
        w_b15 <= i_state(7   downto 0);

        -- col 0: bytes (0, 5, 10, 15)
        u_col0 : entity work.aes_round_column
            port map (
                i_clk       => i_clk,
                i_clk_en    => i_clk_en,
                i_a0        => w_b0,
                i_a1        => w_b5,
                i_a2        => w_b10,
                i_a3        => w_b15,
                i_round_key => i_round_key(127 downto 96),
                o_column    => w_col0
            );

        -- col 1: bytes (4, 9, 14, 3)
        u_col1 : entity work.aes_round_column
            port map (
                i_clk       => i_clk,
                i_clk_en    => i_clk_en,
                i_a0        => w_b4,
                i_a1        => w_b9,
                i_a2        => w_b14,
                i_a3        => w_b3,
                i_round_key => i_round_key(95 downto 64),
                o_column    => w_col1
            );

        -- col 2: bytes (8, 13, 2, 7)
        u_col2 : entity work.aes_round_column
            port map (
                i_clk       => i_clk,
                i_clk_en    => i_clk_en,
                i_a0        => w_b8,
                i_a1        => w_b13,
                i_a2        => w_b2,
                i_a3        => w_b7,
                i_round_key => i_round_key(63 downto 32),
                o_column    => w_col2
            );

        -- col 3: bytes (12, 1, 6, 11)
        u_col3 : entity work.aes_round_column
            port map (
                i_clk       => i_clk,
                i_clk_en    => i_clk_en,
                i_a0        => w_b12,
                i_a1        => w_b1,
                i_a2        => w_b6,
                i_a3        => w_b11,
                i_round_key => i_round_key(31 downto 0),
                o_column    => w_col3
            );

        o_state <= w_col0 & w_col1 & w_col2 & w_col3;
        o_sub_bytes <= (others => '0');  -- no plain SubBytes node (T-tables fuse SB+MC)
    end generate gen_bram;

    ---------------------------------------------------------------------------
    -- LUT mode: single registered round using aes_pkg functions.
    -- Order: SubBytes -> ShiftRows -> MixColumns -> AddRoundKey
    ---------------------------------------------------------------------------
    gen_lut : if ROUND_STYLE = "LUT" generate
        signal r_state_out : std_logic_vector(127 downto 0) := (others => '0');
    begin
        p_ROUND : process(i_clk)
        begin
            if rising_edge(i_clk) then
                if i_clk_en = '1' then
                    r_state_out <= add_round_key(
                                       mix_columns(shift_rows(sub_bytes(i_state))),
                                       i_round_key);
                end if;
            end if;
        end process;
        o_state     <= r_state_out;
        o_sub_bytes <= sub_bytes(i_state);
    end generate gen_lut;

end architecture;
