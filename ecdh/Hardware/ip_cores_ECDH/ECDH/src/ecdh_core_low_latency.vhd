----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ecdh_core_low_latency
-- Module Name   : ecdh_core_low_latency - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Phase-2 (minimum-latency) ECDH core. Same function/interface as
--                 ecdh_top: from k, P=(xb,yb), b computes affine (x,y)=k*P. Uses
--                 ec_scalar_mult_par (self-contained: owns three gf_mul, runs the
--                 ladder step as two parallel rounds) followed by ec_mxy
--                 (y-recovery). Because the ladder no longer needs a shared
--                 gf_alu, there is NO 2:1 ALU arbiter here (unlike Phase 1): the
--                 ladder owns its multipliers and ec_mxy gets its OWN gf_alu
--                 (which it needs for the 3 inversions). Area grows a little
--                 (extra multipliers) — the deliberate Phase-2 trade for latency.
--                 KEYGEN/SHARED routing lives in the ecdh_axis_ip wrapper.
--
-- Dependencies  : work.gf_alu_pkg, work.gf_alu, work.ec_scalar_mult_par,
--                 work.ec_mxy_batch (Phase-2 batch inversion)
--
-- Revision      :
--   0.01 - August 2026 - File Created
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). FSM S_IDLE->S_LADDER->S_MXY->
--   S_DONE. Start strobes toward the children are 1-clock, gated on the child's
--   busy. The gf_alu is only exercised in S_MXY (idle during the ladder).
--   Preconditions unchanged: k >= 1, xb /= 0, k /= ord(P)-1. Constant-time
--   scalar padding (fixed bitlen) is applied on the i_k path one level up.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.gf_alu_pkg.all;

entity ecdh_core_low_latency is
    generic (
        G_M : integer := 4;
        G_D : integer := 1;
        G_F : std_logic_vector := "10011"   -- f WITH the leading bit (G_M+1 bits)
    );
    port (
        i_clk    : in  std_logic;
        i_resetn : in  std_logic;
        i_start  : in  std_logic;
        i_k      : in  std_logic_vector(G_M-1 downto 0);  -- scalar (private key), k >= 1
        i_xb     : in  std_logic_vector(G_M-1 downto 0);  -- x of the point P (xb /= 0)
        i_yb     : in  std_logic_vector(G_M-1 downto 0);  -- y of the point P
        i_b      : in  std_logic_vector(G_M-1 downto 0);  -- curve parameter
        o_x      : out std_logic_vector(G_M-1 downto 0);  -- affine x of k*P
        o_y      : out std_logic_vector(G_M-1 downto 0);  -- affine y of k*P
        o_busy   : out std_logic;
        o_done   : out std_logic
    );
end entity;


architecture rtl of ecdh_core_low_latency is

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_LADDER, S_MXY, S_DONE);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Input snapshot
    ----------------------------------------------------------------------------
    signal r_k, r_xb, r_yb, r_b : std_logic_vector(G_M-1 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- ec_scalar_mult_par (self-contained ladder)
    ----------------------------------------------------------------------------
    signal w_smul_start                               : std_logic;
    signal w_smul_busy, w_smul_done                   : std_logic;
    signal w_smul_x1, w_smul_z1, w_smul_x2, w_smul_z2 : std_logic_vector(G_M-1 downto 0);

    ----------------------------------------------------------------------------
    -- ec_mxy + its own gf_alu
    ----------------------------------------------------------------------------
    signal w_mxy_start              : std_logic;
    signal w_mxy_busy, w_mxy_done   : std_logic;
    signal w_mxy_x, w_mxy_y         : std_logic_vector(G_M-1 downto 0);
    signal w_mxy_alu_start          : std_logic;
    signal w_mxy_alu_op             : alu_op_t;
    signal w_mxy_alu_a, w_mxy_alu_b : std_logic_vector(G_M-1 downto 0);
    signal w_alu_busy, w_alu_done   : std_logic;
    signal w_alu_res                : std_logic_vector(G_M-1 downto 0);

begin

    assert G_F'length = G_M + 1
        report "G_F must be the irreducible polynomial WITH its leading bit (G_M+1 bits)"
        severity failure;

    ----------------------------------------------------------------------------
    -- Ladder: Montgomery x-only, projective output X1..Z2 (owns 3 multipliers)
    ----------------------------------------------------------------------------
    u_smul : entity work.ec_scalar_mult_par
        generic map (
            G_M => G_M,
            G_D => G_D,
            G_F => G_F
        )
        port map (
            i_clk    => i_clk,
            i_resetn => i_resetn,
            i_start  => w_smul_start,
            i_k      => r_k,
            i_xb     => r_xb,
            i_b      => r_b,
            o_x1     => w_smul_x1,
            o_z1     => w_smul_z1,
            o_x2     => w_smul_x2,
            o_z2     => w_smul_z2,
            o_busy   => w_smul_busy,
            o_done   => w_smul_done
        );

    ----------------------------------------------------------------------------
    -- y-recovery + affine conversion (ALU client; has a dedicated gf_alu)
    ----------------------------------------------------------------------------
    u_mxy : entity work.ec_mxy_batch
        generic map (
            G_M => G_M
        )
        port map (
            i_clk       => i_clk,
            i_resetn    => i_resetn,
            i_start     => w_mxy_start,
            i_x1        => w_smul_x1,
            i_z1        => w_smul_z1,
            i_x2        => w_smul_x2,
            i_z2        => w_smul_z2,
            i_xb        => r_xb,
            i_yb        => r_yb,
            o_x         => w_mxy_x,
            o_y         => w_mxy_y,
            o_busy      => w_mxy_busy,
            o_done      => w_mxy_done,
            o_alu_start => w_mxy_alu_start,
            o_alu_op    => w_mxy_alu_op,
            o_alu_a     => w_mxy_alu_a,
            o_alu_b     => w_mxy_alu_b,
            i_alu_busy  => w_alu_busy,
            i_alu_done  => w_alu_done,
            i_alu_res   => w_alu_res
        );

    u_alu : entity work.gf_alu
        generic map (
            G_M => G_M,
            G_D => G_D,
            G_F => G_F
        )
        port map (
            i_clk    => i_clk,
            i_resetn => i_resetn,
            i_op     => w_mxy_alu_op,
            i_start  => w_mxy_alu_start,
            i_a      => w_mxy_alu_a,
            i_b      => w_mxy_alu_b,
            o_res    => w_alu_res,
            o_busy   => w_alu_busy,
            o_done   => w_alu_done
        );

    ----------------------------------------------------------------------------
    -- Start strobes toward the children (1 clock, gated on the child's busy)
    ----------------------------------------------------------------------------
    w_smul_start <= '1' when state_reg = S_LADDER and w_smul_busy = '0' else '0';
    w_mxy_start  <= '1' when state_reg = S_MXY    and w_mxy_busy  = '0' else '0';

    ----------------------------------------------------------------------------
    -- Status outputs
    ----------------------------------------------------------------------------
    o_x    <= w_mxy_x;
    o_y    <= w_mxy_y;
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
                    next_state <= S_LADDER;
                end if;

            when S_LADDER =>
                if w_smul_done = '1' then
                    next_state <= S_MXY;
                end if;

            when S_MXY =>
                if w_mxy_done = '1' then
                    next_state <= S_DONE;
                end if;

            when S_DONE =>
                next_state <= S_IDLE;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Input snapshot in S_IDLE on i_start
    ----------------------------------------------------------------------------
    p_DATAPATH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_k  <= (others => '0');
                r_xb <= (others => '0');
                r_yb <= (others => '0');
                r_b  <= (others => '0');
            elsif state_reg = S_IDLE and i_start = '1' then
                r_k  <= i_k;
                r_xb <= i_xb;
                r_yb <= i_yb;
                r_b  <= i_b;
            end if;
        end if;
    end process;

end architecture;
