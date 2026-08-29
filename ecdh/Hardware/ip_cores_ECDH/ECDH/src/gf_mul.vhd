----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : gf_mul
-- Module Name   : gf_mul - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : GF(2^m) multiplier, bit/digit-serial (G_D bits per clock)
--                 with interleaved reduction (MSB-first shift-and-add, Horner
--                 scheme). Clock count = ceil(m/G_D). Handshake start/busy/done;
--                 the result is valid while o_done pulses.
--
-- Dependencies  : work.gf_alu_pkg (num_bits)
--
-- Revision      :
--   0.01 - June 2026 - File Created
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). Constant time (independent of
--   operand values). Back-to-back capable: holding i_start high in S_DONE
--   reloads operands and skips S_IDLE (one result every ceil(m/G_D)+1 clocks).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.gf_alu_pkg.all;

entity gf_mul is
    generic (
        G_M : integer := 4;
        G_D : integer := 1;                 -- digit width (bits per clock)
        G_F : std_logic_vector := "10011"   -- f WITH the leading bit (G_M+1 bits)
    );
    port (
        i_clk   : in  std_logic;
        i_resetn : in  std_logic;
        i_start : in  std_logic;            -- pulse; a and b are sampled then
        i_a     : in  std_logic_vector(G_M-1 downto 0);
        i_b     : in  std_logic_vector(G_M-1 downto 0);
        o_res   : out std_logic_vector(G_M-1 downto 0);
        o_busy  : out std_logic;
        o_done  : out std_logic             -- 1-clock pulse, o_res valid then
    );
end entity;


architecture rtl of gf_mul is

    function ceil_div(m : integer; d : integer) return integer is
    begin
        return (m + d - 1) / d;
    end function;

    ----------------------------------------------------------------------------
    -- Derived constants
    ----------------------------------------------------------------------------
    -- position copy normalizes an unconstrained generic's (0 to m) range
    constant c_F        : std_logic_vector(G_M downto 0) := G_F;
    constant c_Q        : integer := ceil_div(G_M, G_D);
                          -- digits (clocks) per multiply: ceil(4/1) = 4
    constant c_NUM_BITS : integer := num_bits(c_Q);
                          -- digit counter width: num_bits(4) = 3

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_CALCULATE, S_DONE);
    signal state_reg, next_state : state_t;

    ----------------------------------------------------------------------------
    -- Datapath registers
    ----------------------------------------------------------------------------
    signal r_a           : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- operand a (snapshot)
    signal r_b           : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- operand b (snapshot)
    signal r_accumulator : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- running product mod f
    signal r_cnt         : unsigned(c_NUM_BITS-1 downto 0)
                           := to_unsigned(c_Q, c_NUM_BITS) - 1;                  -- digits remaining (counts down)

    -- One Horner sub-step: acc = acc*x mod f, then conditionally XOR in b when
    -- the addressed bit of a is 1. The index guard covers the padding positions
    -- of the top digit when G_D does not divide G_M (harmless: acc still 0).
    function bit_serial_mult(a           : std_logic_vector(G_M-1 downto 0);
                             b           : std_logic_vector(G_M-1 downto 0);
                             cnt         : integer;
                             accumulator : std_logic_vector(G_M-1 downto 0))
                             return std_logic_vector is
        variable v_acc : std_logic_vector(G_M-1 downto 0) := accumulator;
        variable v_idx : integer                          := cnt;
    begin
        -- shift left by one and reduce if the top bit falls out
        if v_acc(G_M-1) = '1' then
            v_acc := (v_acc(G_M-2 downto 0) & '0') xor c_F(G_M-1 downto 0);
        else
            v_acc := (v_acc(G_M-2 downto 0) & '0');
        end if;

        if v_idx < G_M then    -- index guard (padding part when G_D > 1)
            if a(v_idx) = '1' then
                v_acc := v_acc xor b;
            end if;
        end if;
        return v_acc;
    end function;

begin

    assert G_F'length = G_M + 1
        report "G_F must be the irreducible polynomial WITH its leading bit (G_M+1 bits)"
        severity failure;

    assert G_D >= 1 and G_D <= G_M
        report "G_D must be in 1..G_M (G_D=1 bit-serial, G_D=G_M fully combinational)"
        severity failure;

    ----------------------------------------------------------------------------
    -- Operand snapshot: on start from S_IDLE, or from S_DONE (back-to-back)
    ----------------------------------------------------------------------------
    p_REG_INPUT : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_a <= (others => '0');
                r_b <= (others => '0');
            else
                if (state_reg = S_IDLE or state_reg = S_DONE) and i_start = '1' then
                    r_a <= i_a;
                    r_b <= i_b;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Digit counter: reloaded outside S_CALCULATE, counts down inside
    ----------------------------------------------------------------------------
    p_CNT : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_cnt <= to_unsigned(c_Q, c_NUM_BITS) - 1;
            else
                if state_reg = S_IDLE or state_reg = S_DONE then
                    r_cnt <= to_unsigned(c_Q, c_NUM_BITS) - 1;
                else    -- state_reg = S_CALCULATE
                    r_cnt <= r_cnt - 1;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Accumulator: G_D chained combinational sub-steps per clock, registered
    -- once per digit; digit k covers bits of a at indices k*G_D+i (MSB-first)
    ----------------------------------------------------------------------------
    p_MULTIPLY : process(i_clk)
        variable v_acc : std_logic_vector(G_M-1 downto 0);
        variable v_idx : integer;
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_accumulator <= (others => '0');
            else
                if state_reg = S_CALCULATE then
                    v_acc := r_accumulator;
                    for i in G_D-1 downto 0 loop
                        v_idx := to_integer(r_cnt)*G_D + i;
                        v_acc := bit_serial_mult(r_a, r_b, v_idx, v_acc);
                    end loop;
                    r_accumulator <= v_acc;
                elsif state_reg = S_IDLE or state_reg = S_DONE then
                    r_accumulator <= (others => '0');
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM state register
    ----------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                state_reg <= S_IDLE;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM next state (combinational)
    ----------------------------------------------------------------------------
    p_NEXT_STATE : process(all)
    begin
        next_state <= state_reg;   -- default: stay

        case state_reg is

            when S_IDLE =>
                if i_start = '1' then
                    next_state <= S_CALCULATE;
                end if;

            when S_CALCULATE =>
                if r_cnt = 0 then
                    next_state <= S_DONE;
                end if;

            when S_DONE =>
                -- back-to-back: start held high recycles S_DONE as the load clock
                if i_start = '1' then
                    next_state <= S_CALCULATE;
                else
                    next_state <= S_IDLE;
                end if;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Outputs (combinational from state)
    ----------------------------------------------------------------------------
    p_OUTPUT_SIGNALS : process(all)
    begin
        o_busy <= '0';
        o_done <= '0';
        o_res  <= (others => '0');

        case state_reg is

            when S_IDLE =>
                null;

            when S_CALCULATE =>
                o_busy <= '1';

            when S_DONE =>
                o_res  <= r_accumulator;
                o_done <= '1';

        end case;
    end process;

end architecture;
