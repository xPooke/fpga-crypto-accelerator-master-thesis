--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : aes_pkg
-- Module Name   : aes_pkg - package
-- Tool Version  : Vivado 2025.1
-- Description   : Shared AES constants and combinational round functions:
--                 S-box, Rcon, T-tables (auto-computed at elaboration from the
--                 S-box and MixColumns matrix), and the four AES round
--                 transformations as pure functions.
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
-- Revision      : 0.01 - May 2026 - File created
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package aes_pkg is

    ----------------------------------------------------------------------------
    -- Types
    ----------------------------------------------------------------------------
    type sbox_array_t       is array (0 to 255) of std_logic_vector(7 downto 0);
    type t_table_t          is array (0 to 255) of std_logic_vector(31 downto 0);
    type rcon_array_t       is array (1 to 10)  of std_logic_vector(7 downto 0);

    -- Round key bundle: indices 0..14 cover AES-128 (uses 0..10) and AES-256
    -- (uses 0..14). Upper unused slots are zero for AES-128.
    type arr_round_keys_t   is array (0 to 14) of std_logic_vector(127 downto 0);

    ----------------------------------------------------------------------------
    -- S-box (standard AES forward S-box)
    ----------------------------------------------------------------------------
    constant c_SBOX : sbox_array_t := (
        x"63", x"7c", x"77", x"7b", x"f2", x"6b", x"6f", x"c5",
        x"30", x"01", x"67", x"2b", x"fe", x"d7", x"ab", x"76",
        x"ca", x"82", x"c9", x"7d", x"fa", x"59", x"47", x"f0",
        x"ad", x"d4", x"a2", x"af", x"9c", x"a4", x"72", x"c0",
        x"b7", x"fd", x"93", x"26", x"36", x"3f", x"f7", x"cc",
        x"34", x"a5", x"e5", x"f1", x"71", x"d8", x"31", x"15",
        x"04", x"c7", x"23", x"c3", x"18", x"96", x"05", x"9a",
        x"07", x"12", x"80", x"e2", x"eb", x"27", x"b2", x"75",
        x"09", x"83", x"2c", x"1a", x"1b", x"6e", x"5a", x"a0",
        x"52", x"3b", x"d6", x"b3", x"29", x"e3", x"2f", x"84",
        x"53", x"d1", x"00", x"ed", x"20", x"fc", x"b1", x"5b",
        x"6a", x"cb", x"be", x"39", x"4a", x"4c", x"58", x"cf",
        x"d0", x"ef", x"aa", x"fb", x"43", x"4d", x"33", x"85",
        x"45", x"f9", x"02", x"7f", x"50", x"3c", x"9f", x"a8",
        x"51", x"a3", x"40", x"8f", x"92", x"9d", x"38", x"f5",
        x"bc", x"b6", x"da", x"21", x"10", x"ff", x"f3", x"d2",
        x"cd", x"0c", x"13", x"ec", x"5f", x"97", x"44", x"17",
        x"c4", x"a7", x"7e", x"3d", x"64", x"5d", x"19", x"73",
        x"60", x"81", x"4f", x"dc", x"22", x"2a", x"90", x"88",
        x"46", x"ee", x"b8", x"14", x"de", x"5e", x"0b", x"db",
        x"e0", x"32", x"3a", x"0a", x"49", x"06", x"24", x"5c",
        x"c2", x"d3", x"ac", x"62", x"91", x"95", x"e4", x"79",
        x"e7", x"c8", x"37", x"6d", x"8d", x"d5", x"4e", x"a9",
        x"6c", x"56", x"f4", x"ea", x"65", x"7a", x"ae", x"08",
        x"ba", x"78", x"25", x"2e", x"1c", x"a6", x"b4", x"c6",
        x"e8", x"dd", x"74", x"1f", x"4b", x"bd", x"8b", x"8a",
        x"70", x"3e", x"b5", x"66", x"48", x"03", x"f6", x"0e",
        x"61", x"35", x"57", x"b9", x"86", x"c1", x"1d", x"9e",
        x"e1", x"f8", x"98", x"11", x"69", x"d9", x"8e", x"94",
        x"9b", x"1e", x"87", x"e9", x"ce", x"55", x"28", x"df",
        x"8c", x"a1", x"89", x"0d", x"bf", x"e6", x"42", x"68",
        x"41", x"99", x"2d", x"0f", x"b0", x"54", x"bb", x"16"
    );

    ----------------------------------------------------------------------------
    -- Rcon constants (used by key expansion)
    ----------------------------------------------------------------------------
    constant c_RCON : rcon_array_t := (
        x"01", x"02", x"04", x"08", x"10",
        x"20", x"40", x"80", x"1b", x"36"
    );

    ----------------------------------------------------------------------------
    -- Helper functions
    ----------------------------------------------------------------------------

    -- xtime: multiply by 2 in GF(2^8), reduced by polynomial x^8+x^4+x^3+x+1
    function xtime(b : std_logic_vector(7 downto 0)) return std_logic_vector;

    -- Computes T0[a] = [2*S(a), 1*S(a), 1*S(a), 3*S(a)]
    function make_t0(a : integer) return std_logic_vector;

    -- Cyclic rotate of a 32-bit word right by N bytes
    function rotr_word(w : std_logic_vector(31 downto 0); n : integer)
        return std_logic_vector;

    -- S-box applied to each byte of a 32-bit word (used by key_expansion)
    function sub_word(w : std_logic_vector(31 downto 0))
        return std_logic_vector;

    ----------------------------------------------------------------------------
    -- T-table (pre-computed from the S-box and the MixColumns matrix).
    -- Only T0 is stored: T1, T2, T3 are T0 rotated right by 1, 2, 3 bytes, so
    -- aes_round_column derives them with rotr_word on a T0 read instead of
    -- holding tables of their own.
    ----------------------------------------------------------------------------
    function build_t0 return t_table_t;

    constant c_T0 : t_table_t := build_t0;

    ----------------------------------------------------------------------------
    -- Implementation hint (informative, not enforced from this package):
    --   T0..T3 -> Block RAM   (registered read in aes_round_column)
    --   SBOX   -> distributed LUTs
    --
    -- Vivado IGNORES rom_style applied to package constants (Synth 8-5733).
    -- Forcing the mapping must be done in the architecture that uses the
    -- constant, by copying it into a local signal and attaching the
    -- attribute there. See aes_round_column for the working pattern.
    ----------------------------------------------------------------------------

    ----------------------------------------------------------------------------
    -- AES round-level functions (used by aes_round in LUT mode)
    --   sub_bytes      : 16 parallel S-box lookups
    --   shift_rows     : byte permutation (pure wiring)
    --   mix_columns    : GF(2^8) MixColumns matrix per column
    --   add_round_key  : 128-bit XOR with round key
    ----------------------------------------------------------------------------
    function sub_bytes(state : std_logic_vector(127 downto 0))
        return std_logic_vector;

    function shift_rows(state : std_logic_vector(127 downto 0))
        return std_logic_vector;

    function mix_columns(state : std_logic_vector(127 downto 0))
        return std_logic_vector;

    function add_round_key(state : std_logic_vector(127 downto 0);
                           key   : std_logic_vector(127 downto 0))
        return std_logic_vector;

end package aes_pkg;


package body aes_pkg is

    ----------------------------------------------------------------------------
    -- xtime: if MSB=0, plain left shift; if MSB=1, left shift then XOR 0x1B
    ----------------------------------------------------------------------------
    function xtime(b : std_logic_vector(7 downto 0)) return std_logic_vector is
    begin
        if b(7) = '0' then
            return b(6 downto 0) & '0';
        else
            return (b(6 downto 0) & '0') xor x"1b";
        end if;
    end function;

    ----------------------------------------------------------------------------
    -- make_t0: returns the 32-bit T0[a] entry.
    --   T0[a] = [2*S(a), S(a), S(a), 3*S(a)]   where 3*S(a) = 2*S(a) XOR S(a)
    ----------------------------------------------------------------------------
    function make_t0(a : integer) return std_logic_vector is
        variable v_S   : std_logic_vector(7 downto 0);
        variable v_S2  : std_logic_vector(7 downto 0);
        variable v_S3  : std_logic_vector(7 downto 0);
    begin
        v_S  := c_SBOX(a);
        v_S2 := xtime(v_S);
        v_S3 := v_S2 xor v_S;
        return v_S2 & v_S & v_S & v_S3;
    end function;

    ----------------------------------------------------------------------------
    -- rotr_word: cyclic rotation of a 32-bit word right by n bytes
    ----------------------------------------------------------------------------
    function rotr_word(w : std_logic_vector(31 downto 0); n : integer)
        return std_logic_vector is
        variable v_shift_bits : integer;
    begin
        v_shift_bits := (n mod 4) * 8;
        if v_shift_bits = 0 then
            return w;
        else
            return w(v_shift_bits-1 downto 0) & w(31 downto v_shift_bits);
        end if;
    end function;

    ----------------------------------------------------------------------------
    -- sub_word: S-box lookup on each of the four bytes of a 32-bit word
    ----------------------------------------------------------------------------
    function sub_word(w : std_logic_vector(31 downto 0))
        return std_logic_vector is
        variable v_r : std_logic_vector(31 downto 0);
    begin
        v_r(31 downto 24) := c_SBOX(to_integer(unsigned(w(31 downto 24))));
        v_r(23 downto 16) := c_SBOX(to_integer(unsigned(w(23 downto 16))));
        v_r(15 downto 8)  := c_SBOX(to_integer(unsigned(w(15 downto 8))));
        v_r(7  downto 0)  := c_SBOX(to_integer(unsigned(w(7  downto 0))));
        return v_r;
    end function;

    ----------------------------------------------------------------------------
    -- build_t0: builds the full T0 table by calling make_t0 for every index
    ----------------------------------------------------------------------------
    function build_t0 return t_table_t is
        variable v_result : t_table_t;
    begin
        for i in 0 to 255 loop
            v_result(i) := make_t0(i);
        end loop;
        return v_result;
    end function;


    ----------------------------------------------------------------------------
    -- sub_bytes: apply S-box to all 16 bytes of state
    --   byte k of state lives in bits (127 - k*8) downto (120 - k*8)
    ----------------------------------------------------------------------------
    function sub_bytes(state : std_logic_vector(127 downto 0))
        return std_logic_vector is
        variable v_R : std_logic_vector(127 downto 0);
    begin
        for i in 0 to 15 loop
            v_R(127 - i*8 downto 120 - i*8) :=
                c_SBOX(to_integer(unsigned(state(127 - i*8 downto 120 - i*8))));
        end loop;
        return v_R;
    end function;

    ----------------------------------------------------------------------------
    -- shift_rows: AES ShiftRows on a column-major state
    --   row r is cyclically shifted left by r positions
    -- Output byte positions (col, row):
    --   col 0: (0,0)=b0  (0,1)=b5  (0,2)=b10 (0,3)=b15
    --   col 1: (1,0)=b4  (1,1)=b9  (1,2)=b14 (1,3)=b3
    --   col 2: (2,0)=b8  (2,1)=b13 (2,2)=b2  (2,3)=b7
    --   col 3: (3,0)=b12 (3,1)=b1  (3,2)=b6  (3,3)=b11
    ----------------------------------------------------------------------------
    function shift_rows(state : std_logic_vector(127 downto 0))
        return std_logic_vector is
        variable v_R : std_logic_vector(127 downto 0);
    begin
        -- col 0
        v_R(127 downto 120) := state(127 downto 120);   -- b0
        v_R(119 downto 112) := state(87  downto 80);    -- b5
        v_R(111 downto 104) := state(47  downto 40);    -- b10
        v_R(103 downto 96)  := state(7   downto 0);     -- b15
        -- col 1
        v_R(95  downto 88)  := state(95  downto 88);    -- b4
        v_R(87  downto 80)  := state(55  downto 48);    -- b9
        v_R(79  downto 72)  := state(15  downto 8);     -- b14
        v_R(71  downto 64)  := state(103 downto 96);    -- b3
        -- col 2
        v_R(63  downto 56)  := state(63  downto 56);    -- b8
        v_R(55  downto 48)  := state(23  downto 16);    -- b13
        v_R(47  downto 40)  := state(111 downto 104);   -- b2
        v_R(39  downto 32)  := state(71  downto 64);    -- b7
        -- col 3
        v_R(31  downto 24)  := state(31  downto 24);    -- b12
        v_R(23  downto 16)  := state(119 downto 112);   -- b1
        v_R(15  downto 8)   := state(79  downto 72);    -- b6
        v_R(7   downto 0)   := state(39  downto 32);    -- b11
        return v_R;
    end function;

    ----------------------------------------------------------------------------
    -- mix_one_col (private helper): MixColumns on a single 32-bit column.
    --   s'0 = 2*s0 + 3*s1 + 1*s2 + 1*s3
    --   s'1 = 1*s0 + 2*s1 + 3*s2 + 1*s3
    --   s'2 = 1*s0 + 1*s1 + 2*s2 + 3*s3
    --   s'3 = 3*s0 + 1*s1 + 1*s2 + 2*s3
    -- where 3*x = xtime(x) XOR x and arithmetic is in GF(2^8).
    ----------------------------------------------------------------------------
    function mix_one_col(col : std_logic_vector(31 downto 0))
        return std_logic_vector is
        variable v_S0, v_S1, v_S2, v_S3 : std_logic_vector(7 downto 0);
        variable v_R                    : std_logic_vector(31 downto 0);
    begin
        v_S0 := col(31 downto 24);
        v_S1 := col(23 downto 16);
        v_S2 := col(15 downto 8);
        v_S3 := col(7  downto 0);
        v_R(31 downto 24) := xtime(v_S0) xor (xtime(v_S1) xor v_S1) xor v_S2 xor v_S3;
        v_R(23 downto 16) := v_S0 xor xtime(v_S1) xor (xtime(v_S2) xor v_S2) xor v_S3;
        v_R(15 downto 8)  := v_S0 xor v_S1 xor xtime(v_S2) xor (xtime(v_S3) xor v_S3);
        v_R(7  downto 0)  := (xtime(v_S0) xor v_S0) xor v_S1 xor v_S2 xor xtime(v_S3);
        return v_R;
    end function;

    ----------------------------------------------------------------------------
    -- mix_columns: apply MixColumns to each of the four columns of state
    ----------------------------------------------------------------------------
    function mix_columns(state : std_logic_vector(127 downto 0))
        return std_logic_vector is
        variable v_R : std_logic_vector(127 downto 0);
    begin
        v_R(127 downto 96) := mix_one_col(state(127 downto 96));
        v_R(95  downto 64) := mix_one_col(state(95  downto 64));
        v_R(63  downto 32) := mix_one_col(state(63  downto 32));
        v_R(31  downto 0)  := mix_one_col(state(31  downto 0));
        return v_R;
    end function;

    ----------------------------------------------------------------------------
    -- add_round_key: 128-bit XOR
    ----------------------------------------------------------------------------
    function add_round_key(state : std_logic_vector(127 downto 0);
                           key   : std_logic_vector(127 downto 0))
        return std_logic_vector is
    begin
        return state xor key;
    end function;

end package body aes_pkg;
