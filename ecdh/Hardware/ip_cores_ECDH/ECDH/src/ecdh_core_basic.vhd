----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ecdh_core_basic
-- Module Name   : ecdh_core_basic - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Phase-1 full ECDH core: k*P over GF(2^m) with affine result.
--                 Replaces ec_scalar_mult + ec_mxy + ecdh_top with ONE module and
--                 ONE gf_alu. Instantiates ec_cswap + ec_step_mxy (merged
--                 step/mxy engine) + gf_alu. Runs the Montgomery ladder driving
--                 ec_step_mxy in mode 0 (571x), then y-recovery in mode 1 (1x,
--                 batch inversion), and outputs affine (x,y)=k*P. Because there is
--                 a single ALU client (ec_step_mxy), the ec_step_mxy ALU bus wires
--                 straight to gf_alu — NO 2:1 arbiter (unlike the old ecdh_top).
--
-- Dependencies  : work.gf_alu_pkg, work.gf_alu, work.ec_cswap, work.ec_step_mxy
--
-- Revision      :
--   0.01 - August 2026 - File Created
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). Ladder FSM identical to
--   ec_scalar_mult (S_ALIGN, S_INIT_2P, S_SWAP, S_POINT_STEP, S_RESWAP,
--   S_NEXT_BIT), then a new S_MXY phase before S_DONE. Init trick (2P) and cswap
--   unchanged. Preconditions: k >= 1, xb /= 0, k /= ord(P)-1.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.gf_alu_pkg.all;

entity ecdh_core_basic is
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


architecture rtl of ecdh_core_basic is

    ----------------------------------------------------------------------------
    -- FSM: ladder (as ec_scalar_mult) + S_MXY phase
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_ALIGN, S_INIT_2P, S_SWAP, S_POINT_STEP,
                     S_RESWAP, S_NEXT_BIT, S_MXY, S_DONE);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Datapath registers
    ----------------------------------------------------------------------------
    signal r_x1, r_z1, r_x2, r_z2 : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- ladder state
    signal r_k                    : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal r_xb, r_yb, r_b        : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal r_cnt                  : integer range 0 to G_M := 0;

    signal w_bit : std_logic;

    ----------------------------------------------------------------------------
    -- Instance wiring
    ----------------------------------------------------------------------------
    signal w_sx1, w_sz1, w_sx2, w_sz2 : std_logic_vector(G_M-1 downto 0);  -- cswap out

    signal w_su_start, w_su_mode      : std_logic;
    signal w_su_busy, w_su_done       : std_logic;
    signal w_su_x2, w_su_z2           : std_logic_vector(G_M-1 downto 0);  -- init-trick mux
    signal w_nx1, w_nz1, w_nx2, w_nz2 : std_logic_vector(G_M-1 downto 0);  -- mode-0 outputs
    signal w_mx, w_my                 : std_logic_vector(G_M-1 downto 0);  -- mode-1 outputs

    -- gf_alu bus (single client: ec_step_mxy)
    signal w_alu_start            : std_logic;
    signal w_alu_op               : alu_op_t;
    signal w_alu_a, w_alu_b       : std_logic_vector(G_M-1 downto 0);
    signal w_alu_busy, w_alu_done : std_logic;
    signal w_alu_res              : std_logic_vector(G_M-1 downto 0);

begin

    assert G_F'length = G_M + 1
        report "G_F must be the irreducible polynomial WITH its leading bit (G_M+1 bits)"
        severity failure;

    w_bit <= r_k(G_M-1);

    ----------------------------------------------------------------------------
    -- cswap (combinational)
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

    ----------------------------------------------------------------------------
    -- Merged step/mxy engine (mode 0 = step, mode 1 = mxy batch)
    ----------------------------------------------------------------------------
    u_su : entity work.ec_step_mxy
        generic map (
            G_M => G_M
        )
        port map (
            i_clk       => i_clk,
            i_resetn    => i_resetn,
            i_start     => w_su_start,
            i_mode      => w_su_mode,
            i_x1        => r_x1,
            i_z1        => r_z1,
            i_x2        => w_su_x2,
            i_z2        => w_su_z2,
            i_xb        => r_xb,
            i_yb        => r_yb,
            i_b         => r_b,
            o_x1        => w_nx1,
            o_z1        => w_nz1,
            o_x2        => w_nx2,
            o_z2        => w_nz2,
            o_x         => w_mx,
            o_y         => w_my,
            o_busy      => w_su_busy,
            o_done      => w_su_done,
            o_alu_start => w_alu_start,
            o_alu_op    => w_alu_op,
            o_alu_a     => w_alu_a,
            o_alu_b     => w_alu_b,
            i_alu_busy  => w_alu_busy,
            i_alu_done  => w_alu_done,
            i_alu_res   => w_alu_res
        );

    ----------------------------------------------------------------------------
    -- Single arithmetic resource (no arbiter — one client)
    ----------------------------------------------------------------------------
    u_alu : entity work.gf_alu
        generic map (
            G_M => G_M,
            G_D => G_D,
            G_F => G_F
        )
        port map (
            i_clk    => i_clk,
            i_resetn => i_resetn,
            i_op     => w_alu_op,
            i_start  => w_alu_start,
            i_a      => w_alu_a,
            i_b      => w_alu_b,
            o_res    => w_alu_res,
            o_busy   => w_alu_busy,
            o_done   => w_alu_done
        );

    ----------------------------------------------------------------------------
    -- Init trick: in S_INIT_2P the engine sees P2 = P1; its nP1 = 2P is kept.
    ----------------------------------------------------------------------------
    w_su_x2 <= r_x1 when state_reg = S_INIT_2P else r_x2;
    w_su_z2 <= r_z1 when state_reg = S_INIT_2P else r_z2;

    -- mode: 1 only in the y-recovery phase
    w_su_mode <= '1' when state_reg = S_MXY else '0';

    -- 1-clock start strobe, gated on busy: step (init / point_step) and mxy
    w_su_start <= '1' when (state_reg = S_INIT_2P or state_reg = S_POINT_STEP
                            or state_reg = S_MXY) and w_su_busy = '0' else '0';

    ----------------------------------------------------------------------------
    -- Status outputs
    ----------------------------------------------------------------------------
    -- affine result read straight from the engine (held stable while idle) — no
    -- extra output register (same as ecdh_core_low_latency).
    o_x    <= w_mx;
    o_y    <= w_my;
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
        next_state <= state_reg;

        case state_reg is

            when S_IDLE =>
                if i_start = '1' then
                    next_state <= S_ALIGN;
                end if;

            when S_ALIGN =>
                if r_k(G_M-1) = '1' then
                    next_state <= S_INIT_2P;
                elsif r_cnt = 0 then
                    next_state <= S_DONE;   -- defensive: k=0 (no mxy)
                end if;

            when S_INIT_2P =>
                if w_su_done = '1' then
                    if r_cnt = 0 then
                        next_state <= S_MXY;    -- k=1: ladder result is (P, 2P)
                    else
                        next_state <= S_SWAP;
                    end if;
                end if;

            when S_SWAP =>
                next_state <= S_POINT_STEP;

            when S_POINT_STEP =>
                if w_su_done = '1' then
                    next_state <= S_RESWAP;
                end if;

            when S_RESWAP =>
                next_state <= S_NEXT_BIT;

            when S_NEXT_BIT =>
                if r_cnt = 1 then
                    next_state <= S_MXY;
                else
                    next_state <= S_SWAP;
                end if;

            when S_MXY =>
                if w_su_done = '1' then
                    next_state <= S_DONE;
                end if;

            when S_DONE =>
                next_state <= S_IDLE;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Datapath
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
                r_xb <= (others => '0');
                r_yb <= (others => '0');
                r_b  <= (others => '0');
                r_cnt <= 0;
            else
                case state_reg is

                    when S_IDLE =>
                        if i_start = '1' then
                            r_k  <= i_k;
                            r_xb <= i_xb;
                            r_yb <= i_yb;
                            r_b  <= i_b;
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
                        if w_su_done = '1' then
                            r_x2 <= w_nx1;   -- 2P = mdouble(P)
                            r_z2 <= w_nz1;
                        end if;

                    when S_SWAP =>
                        r_x1 <= w_sx1;
                        r_z1 <= w_sz1;
                        r_x2 <= w_sx2;
                        r_z2 <= w_sz2;

                    when S_POINT_STEP =>
                        if w_su_done = '1' then
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

                    when others =>
                        null;   -- S_MXY: result read combinationally (o_x/o_y = w_mx/w_my)

                end case;
            end if;
        end if;
    end process;

end architecture;
