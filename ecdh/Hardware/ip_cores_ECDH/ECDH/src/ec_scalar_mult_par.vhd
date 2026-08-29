----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ec_scalar_mult_par
-- Module Name   : ec_scalar_mult_par - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Phase-2 (minimum-latency) Montgomery ladder. Identical
--                 conductor FSM as ec_scalar_mult (per bit: swap -> point_step ->
--                 reswap; init trick for 2P; S_ALIGN for bin(k)[3:]), but the
--                 ladder step is ec_point_step_par, which OWNS three gf_mul
--                 instances and runs the step as two parallel rounds. This module
--                 therefore has NO ALU-client bus and instantiates no shared
--                 gf_alu — it is self-contained. Output is the projective state
--                 (X1,Z1,X2,Z2); affine x/y is recovered later by ec_mxy.
--                 Golden model: scalar_mult_ct in ec_ladder.py.
--
-- Dependencies  : work.ec_cswap, work.ec_point_step_par
--
-- Revision      :
--   0.01 - August 2026 - File Created
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). Result bit-identical to
--   ec_scalar_mult (same golden vectors ladder_vec_*.txt); only the per-step
--   latency changes. Precondition: k >= 1 (bitlen(k) timing leak noted in the
--   SPEC; constant-time padding is applied one level up, in ecdh_top).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity ec_scalar_mult_par is
    generic (
        G_M : integer := 4;
        G_D : integer := 1;                 -- multiplier digit width
        G_F : std_logic_vector := "10011"   -- f WITH the leading bit (G_M+1 bits)
    );
    port (
        i_clk    : in  std_logic;
        i_resetn : in  std_logic;
        i_start  : in  std_logic;
        i_k      : in  std_logic_vector(G_M-1 downto 0);  -- scalar, k >= 1
        i_xb     : in  std_logic_vector(G_M-1 downto 0);  -- x of the base point P
        i_b      : in  std_logic_vector(G_M-1 downto 0);  -- curve parameter
        o_x1     : out std_logic_vector(G_M-1 downto 0);  -- x(k*P) = X1/Z1
        o_z1     : out std_logic_vector(G_M-1 downto 0);
        o_x2     : out std_logic_vector(G_M-1 downto 0);  -- x((k+1)*P) = X2/Z2
        o_z2     : out std_logic_vector(G_M-1 downto 0);
        o_busy   : out std_logic;
        o_done   : out std_logic
    );
end entity;


architecture rtl of ec_scalar_mult_par is

    ----------------------------------------------------------------------------
    -- FSM (same as ec_scalar_mult)
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_ALIGN, S_INIT_2P, S_SWAP, S_POINT_STEP,
                     S_RESWAP, S_NEXT_BIT, S_DONE);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Datapath registers
    ----------------------------------------------------------------------------
    signal r_x1, r_z1, r_x2, r_z2 : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal r_k                    : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal r_cnt                  : integer range 0 to G_M := 0;
    -- xb, b are NOT snapshotted here: read straight from the ports (the parent
    -- ecdh_core_low_latency holds them stable for the whole k*P).

    signal w_bit : std_logic;   -- current scalar bit = MSB of r_k

    ----------------------------------------------------------------------------
    -- Instance wiring
    ----------------------------------------------------------------------------
    signal w_sx1, w_sz1, w_sx2, w_sz2 : std_logic_vector(G_M-1 downto 0);

    signal w_step_start               : std_logic;
    signal w_step_busy, w_step_done   : std_logic;
    signal w_nx1, w_nz1, w_nx2, w_nz2 : std_logic_vector(G_M-1 downto 0);
    signal w_step_x2, w_step_z2       : std_logic_vector(G_M-1 downto 0);  -- init-trick mux

begin

    w_bit <= r_k(G_M-1);

    ----------------------------------------------------------------------------
    -- Instances: cswap (comb.) + parallel point_step (owns its multipliers)
    ----------------------------------------------------------------------------
    u_cswap : entity work.ec_cswap
        generic map (
            G_M => G_M
        )
        port map (
            i_swap => w_bit,
            i_x1   => r_x1,
            i_z1   => r_z1,
            i_x2   => r_x2,
            i_z2   => r_z2,
            o_x1   => w_sx1,
            o_z1   => w_sz1,
            o_x2   => w_sx2,
            o_z2   => w_sz2
        );

    u_step : entity work.ec_point_step_par
        generic map (
            G_M => G_M,
            G_D => G_D,
            G_F => G_F
        )
        port map (
            i_clk    => i_clk,
            i_resetn => i_resetn,
            i_start  => w_step_start,
            i_x1     => r_x1,
            i_z1     => r_z1,
            i_x2     => w_step_x2,
            i_z2     => w_step_z2,
            i_xb     => i_xb,
            i_b      => i_b,
            o_x1     => w_nx1,
            o_z1     => w_nz1,
            o_x2     => w_nx2,
            o_z2     => w_nz2,
            o_busy   => w_step_busy,
            o_done   => w_step_done
        );

    ----------------------------------------------------------------------------
    -- Init trick: in S_INIT_2P the step receives P2 = P1; its nP1 = 2P is the
    -- only output we keep.
    ----------------------------------------------------------------------------
    w_step_x2 <= r_x1 when state_reg = S_INIT_2P else r_x2;
    w_step_z2 <= r_z1 when state_reg = S_INIT_2P else r_z2;

    ----------------------------------------------------------------------------
    -- Strobe toward the step, gated on busy (1-clock)
    ----------------------------------------------------------------------------
    w_step_start <= '1' when (state_reg = S_INIT_2P or state_reg = S_POINT_STEP)
                             and w_step_busy = '0' else '0';

    ----------------------------------------------------------------------------
    -- Status outputs
    ----------------------------------------------------------------------------
    o_x1 <= r_x1;
    o_z1 <= r_z1;
    o_x2 <= r_x2;
    o_z2 <= r_z2;
    o_busy <= '0' when state_reg = S_IDLE else '1';
    o_done <= '1' when state_reg = S_DONE else '0';

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
                    next_state <= S_ALIGN;
                end if;

            when S_ALIGN =>
                if r_k(G_M-1) = '1' then
                    next_state <= S_INIT_2P;
                elsif r_cnt = 0 then
                    next_state <= S_DONE;   -- defensive: k=0
                end if;

            when S_INIT_2P =>
                if w_step_done = '1' then
                    if r_cnt = 0 then
                        next_state <= S_DONE;   -- k=1
                    else
                        next_state <= S_SWAP;
                    end if;
                end if;

            when S_SWAP =>
                next_state <= S_POINT_STEP;    -- 1 clock

            when S_POINT_STEP =>
                if w_step_done = '1' then
                    next_state <= S_RESWAP;
                end if;

            when S_RESWAP =>
                next_state <= S_NEXT_BIT;      -- 1 clock

            when S_NEXT_BIT =>
                if r_cnt = 1 then
                    next_state <= S_DONE;
                else
                    next_state <= S_SWAP;
                end if;

            when S_DONE =>
                next_state <= S_IDLE;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Datapath: all register writes, by state
    ----------------------------------------------------------------------------
    p_DATAPATH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_x1 <= (others => '0');
                r_z1 <= (others => '0');
                r_x2 <= (others => '0');
                r_z2 <= (others => '0');
                r_k  <= (others => '0');
                r_cnt <= 0;
            else
                case state_reg is

                    when S_IDLE =>
                        if i_start = '1' then
                            r_k  <= i_k;
                            r_x1 <= i_xb;
                            r_z1 <= (0 => '1', others => '0');
                            r_x2 <= i_xb;
                            r_z2 <= (0 => '1', others => '0');
                            r_cnt <= G_M;
                        end if;

                    when S_ALIGN =>
                        r_k <= r_k(G_M-2 downto 0) & '0';
                        if r_cnt > 0 then
                            r_cnt <= r_cnt - 1;
                        end if;

                    when S_INIT_2P =>
                        if w_step_done = '1' then
                            r_x2 <= w_nx1;
                            r_z2 <= w_nz1;
                        end if;

                    when S_SWAP =>
                        r_x1 <= w_sx1;
                        r_z1 <= w_sz1;
                        r_x2 <= w_sx2;
                        r_z2 <= w_sz2;

                    when S_POINT_STEP =>
                        if w_step_done = '1' then
                            r_x1 <= w_nx1;
                            r_z1 <= w_nz1;
                            r_x2 <= w_nx2;
                            r_z2 <= w_nz2;
                        end if;

                    when S_RESWAP =>
                        r_x1 <= w_sx1;
                        r_z1 <= w_sz1;
                        r_x2 <= w_sx2;
                        r_z2 <= w_sz2;

                    when S_NEXT_BIT =>
                        r_k <= r_k(G_M-2 downto 0) & '0';
                        if r_cnt > 0 then
                            r_cnt <= r_cnt - 1;
                        end if;

                    when S_DONE =>
                        null;

                end case;
            end if;
        end if;
    end process;

end architecture;
