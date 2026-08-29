--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : GHASH_pipelined
-- Module Name   : GHASH_pipelined - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : GHASH accumulator for GCM with a pipelined GF(2^128)
--                 multiplier. On every valid input block X_i the next
--                 accumulator state is
--                   Y_{i+1} = (Y_i XOR X_i) * H   (over GF(2^128))
--                 The multiplier inside the loop is split across two
--                 cycles. Stage 1 (combinational): r_Y XOR X, bit_reverse,
--                 dual 64-bit Karatsuba decomposition, then 9 parallel
--                 GF2_Karatsuba_32 instances producing 9 x 63-bit partial
--                 products. A 567-bit register bank r_p32 captures them.
--                 Stage 2 (combinational): inner Karatsuba_64-level
--                 combines, outer Karatsuba_128-level combine, GF(2^128)
--                 reduction, bit_reverse back to NIST order, then r_Y
--                 captures the result.
--                 r_Y lags i_valid by two cycles. i_valid is delayed by
--                 one cycle (r_valid_d1) and gates the r_Y capture. The
--                 wrapper must drive i_valid='1' at most every other cycle.
-- Dependencies  : ieee.std_logic_1164, work.GF2_Karatsuba_32,
--                 work.GF2_Reduction_128
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 Active-low reset.
--                 NIST byte order vs math (bit-reversed) order: NIST GCM
--                 treats the MSB of byte 0 as the lowest-degree coefficient
--                 of the polynomial; standard GF(2) multipliers treat bit 0
--                 as the lowest-degree coefficient. Hence the bit_reverse
--                 helpers on the inputs and outputs of the multiplier.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity GHASH_pipelined is
    port (
        i_clk     : in  std_logic;
        i_rstn    : in  std_logic;
        i_init    : in  std_logic;                       -- sync clear; assert before each new packet
        i_valid   : in  std_logic;                       -- 1-cycle pulse: i_X holds a valid AAD/CT block
        i_last    : in  std_logic;                       -- assert with i_valid on the packet's final block
        i_X       : in  std_logic_vector(127 downto 0);  -- AAD/CT block, NIST byte order
        i_H       : in  std_logic_vector(127 downto 0);  -- hash sub-key H = AES_K(0^128), NIST order
        o_Y       : out std_logic_vector(127 downto 0);  -- accumulated GHASH register
        o_Y_valid : out std_logic                        -- pulses one cycle after the final r_valid_d1 beat
    );
end entity;

architecture rtl of GHASH_pipelined is

    function bit_reverse(v : std_logic_vector) return std_logic_vector is
        variable v_R : std_logic_vector(v'range);
    begin
        for i in v'range loop
            v_R(i) := v(v'high - i);
        end loop;
        return v_R;
    end function;

    -- Multiplier operands in math domain
    signal w_xor    : std_logic_vector(127 downto 0);
    signal w_A_math : std_logic_vector(127 downto 0);
    signal w_B_math : std_logic_vector(127 downto 0);

    -- 128-bit -> 64-bit outer split (lo, hi, xx)
    signal w_A_lo, w_A_hi, w_A_xx : std_logic_vector(63 downto 0);
    signal w_B_lo, w_B_hi, w_B_xx : std_logic_vector(63 downto 0);

    -- 64-bit -> 32-bit inner split, 3 outer slots
    type slot64_t is record
        lo : std_logic_vector(31 downto 0);
        hi : std_logic_vector(31 downto 0);
        xx : std_logic_vector(31 downto 0);
    end record;
    type slot64_arr_t is array (0 to 2) of slot64_t;

    signal w_A_slots : slot64_arr_t;
    signal w_B_slots : slot64_arr_t;

    -- 9 parallel Karatsuba_32 outputs (combinational)
    type prod63_t is array (0 to 8) of std_logic_vector(62 downto 0);
    signal w_p32 : prod63_t;

    -- Pipeline register: 9 x 63 = 567 bits
    signal r_p32 : prod63_t := (others => (others => '0'));

    -- Stage 2 combine outputs
    signal w_p64_lo : std_logic_vector(126 downto 0);
    signal w_p64_hi : std_logic_vector(126 downto 0);
    signal w_p64_xx : std_logic_vector(126 downto 0);
    signal w_prod   : std_logic_vector(254 downto 0);

    -- Reduction output and back-to-NIST
    signal w_mult_math : std_logic_vector(127 downto 0);
    signal w_mult      : std_logic_vector(127 downto 0);

    -- 1-cycle delayed valid/last aligned with the pipeline
    signal r_valid_d1 : std_logic := '0';
    signal r_last_d1  : std_logic := '0';

    -- Accumulator
    signal r_Y       : std_logic_vector(127 downto 0) := (others => '0');
    signal r_Y_valid : std_logic := '0';

begin

    ----------------------------------------------------------------------------
    -- Stage 0: GHASH step, convert to math domain
    ----------------------------------------------------------------------------
    w_xor    <= r_Y xor i_X;
    w_A_math <= bit_reverse(w_xor);
    w_B_math <= bit_reverse(i_H);

    ----------------------------------------------------------------------------
    -- Outer Karatsuba_128 split: 128b -> three 64b operands
    ----------------------------------------------------------------------------
    w_A_lo <= w_A_math(63 downto 0);
    w_A_hi <= w_A_math(127 downto 64);
    w_A_xx <= w_A_lo xor w_A_hi;

    w_B_lo <= w_B_math(63 downto 0);
    w_B_hi <= w_B_math(127 downto 64);
    w_B_xx <= w_B_lo xor w_B_hi;

    ----------------------------------------------------------------------------
    -- Inner Karatsuba_64 split: each 64b -> three 32b operands
    ----------------------------------------------------------------------------
    w_A_slots(0).lo <= w_A_lo(31 downto 0);
    w_A_slots(0).hi <= w_A_lo(63 downto 32);
    w_A_slots(0).xx <= w_A_lo(31 downto 0) xor w_A_lo(63 downto 32);

    w_A_slots(1).lo <= w_A_hi(31 downto 0);
    w_A_slots(1).hi <= w_A_hi(63 downto 32);
    w_A_slots(1).xx <= w_A_hi(31 downto 0) xor w_A_hi(63 downto 32);

    w_A_slots(2).lo <= w_A_xx(31 downto 0);
    w_A_slots(2).hi <= w_A_xx(63 downto 32);
    w_A_slots(2).xx <= w_A_xx(31 downto 0) xor w_A_xx(63 downto 32);

    w_B_slots(0).lo <= w_B_lo(31 downto 0);
    w_B_slots(0).hi <= w_B_lo(63 downto 32);
    w_B_slots(0).xx <= w_B_lo(31 downto 0) xor w_B_lo(63 downto 32);

    w_B_slots(1).lo <= w_B_hi(31 downto 0);
    w_B_slots(1).hi <= w_B_hi(63 downto 32);
    w_B_slots(1).xx <= w_B_hi(31 downto 0) xor w_B_hi(63 downto 32);

    w_B_slots(2).lo <= w_B_xx(31 downto 0);
    w_B_slots(2).hi <= w_B_xx(63 downto 32);
    w_B_slots(2).xx <= w_B_xx(31 downto 0) xor w_B_xx(63 downto 32);

    ----------------------------------------------------------------------------
    -- 9 parallel 32x32 Karatsuba multipliers (combinational).
    -- Index = 3*outer_slot + inner_kind  (kind: 0=lo, 1=hi, 2=xx)
    ----------------------------------------------------------------------------
    gen_outer : for s in 0 to 2 generate
        u_k32_lo : entity work.GF2_Karatsuba_32
            port map (i_A => w_A_slots(s).lo,
                      i_B => w_B_slots(s).lo,
                      o_P => w_p32(3*s + 0));
        u_k32_hi : entity work.GF2_Karatsuba_32
            port map (i_A => w_A_slots(s).hi,
                      i_B => w_B_slots(s).hi,
                      o_P => w_p32(3*s + 1));
        u_k32_xx : entity work.GF2_Karatsuba_32
            port map (i_A => w_A_slots(s).xx,
                      i_B => w_B_slots(s).xx,
                      o_P => w_p32(3*s + 2));
    end generate gen_outer;

    ----------------------------------------------------------------------------
    -- Pipeline register: 9 x 63-bit Karatsuba_32 products
    ----------------------------------------------------------------------------
    p_PROD_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' or i_init = '1' then
                for i in 0 to 8 loop
                    r_p32(i) <= (others => '0');
                end loop;
            else
                r_p32 <= w_p32;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Stage 2: inner Karatsuba_64 combines, one per outer slot
    ----------------------------------------------------------------------------
    p_K64_COMBINE : process(r_p32)
        variable v_p0, v_p1, v_p2, v_PM : std_logic_vector(62 downto 0);
        variable v_R                    : std_logic_vector(126 downto 0);
    begin
        -- outer slot 0 -> w_p64_lo
        v_p0 := r_p32(0); v_p1 := r_p32(1); v_p2 := r_p32(2);
        v_PM := v_p2 xor v_p1 xor v_p0;
        v_R  := (others => '0');
        v_R(62 downto 0)   := v_R(62 downto 0)   xor v_p0;
        v_R(94 downto 32)  := v_R(94 downto 32)  xor v_PM;
        v_R(126 downto 64) := v_R(126 downto 64) xor v_p1;
        w_p64_lo <= v_R;

        -- outer slot 1 -> w_p64_hi
        v_p0 := r_p32(3); v_p1 := r_p32(4); v_p2 := r_p32(5);
        v_PM := v_p2 xor v_p1 xor v_p0;
        v_R  := (others => '0');
        v_R(62 downto 0)   := v_R(62 downto 0)   xor v_p0;
        v_R(94 downto 32)  := v_R(94 downto 32)  xor v_PM;
        v_R(126 downto 64) := v_R(126 downto 64) xor v_p1;
        w_p64_hi <= v_R;

        -- outer slot 2 -> w_p64_xx
        v_p0 := r_p32(6); v_p1 := r_p32(7); v_p2 := r_p32(8);
        v_PM := v_p2 xor v_p1 xor v_p0;
        v_R  := (others => '0');
        v_R(62 downto 0)   := v_R(62 downto 0)   xor v_p0;
        v_R(94 downto 32)  := v_R(94 downto 32)  xor v_PM;
        v_R(126 downto 64) := v_R(126 downto 64) xor v_p1;
        w_p64_xx <= v_R;
    end process;

    ----------------------------------------------------------------------------
    -- Outer Karatsuba_128 combine -> 255-bit unreduced product
    ----------------------------------------------------------------------------
    p_K128_COMBINE : process(w_p64_lo, w_p64_hi, w_p64_xx)
        variable v_PM : std_logic_vector(126 downto 0);
        variable v_R  : std_logic_vector(254 downto 0);
    begin
        v_PM := w_p64_xx xor w_p64_hi xor w_p64_lo;
        v_R  := (others => '0');
        v_R(126 downto 0)   := v_R(126 downto 0)   xor w_p64_lo;
        v_R(190 downto 64)  := v_R(190 downto 64)  xor v_PM;
        v_R(254 downto 128) := v_R(254 downto 128) xor w_p64_hi;
        w_prod <= v_R;
    end process;

    ----------------------------------------------------------------------------
    -- Polynomial reduction mod x^128 + x^7 + x^2 + x + 1
    ----------------------------------------------------------------------------
    u_red : entity work.GF2_Reduction_128
        port map (
            i_P => w_prod,
            o_C => w_mult_math
        );

    -- Back to NIST byte order
    w_mult <= bit_reverse(w_mult_math);

    ----------------------------------------------------------------------------
    -- 1-cycle valid/last delay aligned with the r_p32 -> w_mult flow
    ----------------------------------------------------------------------------
    p_VALID_DELAY : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' or i_init = '1' then
                r_valid_d1 <= '0';
                r_last_d1  <= '0';
            else
                r_valid_d1 <= i_valid;
                r_last_d1  <= i_last;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Accumulator: capture the reduced product on the delayed valid cycle
    ----------------------------------------------------------------------------
    p_REG_Y : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' or i_init = '1' then
                r_Y       <= (others => '0');
                r_Y_valid <= '0';
            else
                r_Y_valid <= '0';
                if r_valid_d1 = '1' then
                    r_Y <= w_mult;
                    if r_last_d1 = '1' then
                        r_Y_valid <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    o_Y       <= r_Y;
    o_Y_valid <= r_Y_valid;

end architecture;
