--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : GHASH_single
-- Module Name   : GHASH_single - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : GHASH accumulator for GCM. On every valid input block X_i
--                 (an AAD or CT word, NIST byte order), updates the GHASH
--                 register Y as:
--                   Y_{i+1} = (Y_i XOR X_i) * H   (over GF(2^128))
--                 where H is the hash sub-key H = AES_K(0^128). The
--                 multiplier expects operands in math (bit-reversed) order,
--                 so each operand is bit-reversed before the multiply and
--                 the product is bit-reversed back to NIST order. i_init
--                 clears Y (call once before the first block of each
--                 packet). o_Y_valid pulses one cycle after a beat with
--                 i_last='1' to mark the final GHASH for the packet.
-- Dependencies  : ieee.std_logic_1164, work.gf2_multiplier_128
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 Active-low reset.
--                 NIST byte order vs math (bit-reversed) order: NIST GCM
--                 treats the MSB of byte 0 as the lowest-degree coefficient
--                 of the polynomial; standard GF(2) multipliers treat bit 0
--                 as the lowest-degree coefficient. Hence the bit_reverse
--                 helpers wrapping the multiplier ports.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity GHASH_single is
    port (
        i_clk     : in  std_logic;
        i_rstn    : in  std_logic;
        i_init    : in  std_logic;                       -- sync clear; assert before each new packet
        i_valid   : in  std_logic;                       -- 1-cycle pulse: i_X holds a valid AAD/CT block
        i_last    : in  std_logic;                       -- assert with i_valid on the packet's final block
        i_X       : in  std_logic_vector(127 downto 0);  -- AAD/CT block, NIST byte order
        i_H       : in  std_logic_vector(127 downto 0);  -- hash sub-key H = AES_K(0^128), NIST order
        o_Y       : out std_logic_vector(127 downto 0);  -- accumulated GHASH register
        o_Y_valid : out std_logic                        -- pulses one cycle after the i_last beat
    );
end entity;

architecture rtl of GHASH_single is

    -- NIST GHASH uses opposite bit ordering from typical GF(2^128) multipliers
    function bit_reverse(v : std_logic_vector) return std_logic_vector is
        variable v_R : std_logic_vector(v'range);
    begin
        for i in v'range loop
            v_R(i) := v(v'high - i);
        end loop;
        return v_R;
    end function;

    signal r_Y       : std_logic_vector(127 downto 0) := (others => '0');  -- GHASH accumulator
    signal r_Y_valid : std_logic := '0';                                   -- output strobe (1 cycle after i_last)

    signal w_xor       : std_logic_vector(127 downto 0);  -- (r_Y XOR i_X), NIST order
    signal w_xor_rev   : std_logic_vector(127 downto 0);  -- (r_Y XOR i_X) in math order, feeds multiplier
    signal w_H_rev     : std_logic_vector(127 downto 0);  -- H in math order, feeds multiplier
    signal w_mult_rev  : std_logic_vector(127 downto 0);  -- multiplier product in math order
    signal w_mult      : std_logic_vector(127 downto 0);  -- product back in NIST order

begin

    -- GHASH step (NIST domain)
    w_xor <= r_Y xor i_X;

    -- Convert to math domain for multiplier
    w_xor_rev <= bit_reverse(w_xor);
    w_H_rev   <= bit_reverse(i_H);

    -- GF(2^128) multiplier
    u_mult : entity work.GF2_Multiplier_128
        port map (
            i_A => w_xor_rev,
            i_B => w_H_rev,
            o_C => w_mult_rev
        );

    -- Convert back to NIST domain
    w_mult <= bit_reverse(w_mult_rev);

    p_REG_Y : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_Y       <= (others => '0');
                r_Y_valid <= '0';
            elsif i_init = '1' then
                r_Y       <= (others => '0');
                r_Y_valid <= '0';
            else
                r_Y_valid <= '0';
                if i_valid = '1' then
                    r_Y <= w_mult;
                    if i_last = '1' then
                        r_Y_valid <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    o_Y       <= r_Y;
    o_Y_valid <= r_Y_valid;

end architecture;
