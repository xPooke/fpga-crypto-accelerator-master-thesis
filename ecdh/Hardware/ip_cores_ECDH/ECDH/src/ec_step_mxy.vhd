----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ec_step_mxy
-- Module Name   : ec_step_mxy - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Phase-1 MERGED ladder-step + y-recovery, ALU client with an
--                 i_mode input:
--                   mode 0 = ec_point_step (madd + mdouble), 14-op microprogram;
--                   mode 1 = y-recovery with Montgomery BATCH inversion
--                            (3 INV -> 1 INV + 6 MUL), 18-op microprogram.
--                 One shared FSM (S_IDLE/S_ISSUE/S_WAIT/S_DONE + r_pc), one
--                 shared register bank and one ALU bus for both roles. Since the
--                 step (571x during the ladder) and mxy (1x at the end) never run
--                 at the same time, the common scratch registers are shared
--                 instead of duplicated across two modules; mxy x/y also reuse the
--                 nX1/nZ1 result slots. Golden: madd/mdouble + Mxy in ec_ladder.py
--                 (batch inversion is an algebraic rearrangement -> identical x,y).
--
-- Dependencies  : work.gf_alu_pkg (alu_op_t, num_bits); connects to work.gf_alu
--
-- Revision      :
--   0.01 - August 2026 - File Created
--   0.02 - August 2026 - Dropped the input snapshot (i_x1..i_b, i_mode): the
--                        microprogram only READS the inputs, so no internal copy
--                        is needed. Saves 7 words (~4k FF on B-571).
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). NO input snapshot: the inputs
--   i_x1,i_z1,i_x2,i_z2,i_xb,i_yb,i_b AND i_mode must be held STABLE by the parent
--   for the whole operation (they are never registered here). The parent
--   ecdh_core_basic guarantees this (it updates the ladder state only on this module's
--   o_done, after the microprogram has finished reading). Registered state is only
--   the scratch (r_t1..r_t5), the results (r_nx1,r_nz1,r_nx2,r_nz2) and r_pc.
--   c_NUM_OPS is 14 (mode 0) / 18 (mode 1); r_pc is 5 bits (num_bits(18)).
--   Result routing: mode 0 -> o_x1..o_z2; mode 1 -> o_x,o_y (share nX1,nZ1).
--   Precondition mode 1: xb,Z1,Z2 /= 0.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.gf_alu_pkg.all;

entity ec_step_mxy is
    generic (
        G_M : integer := 4
    );
    port (
        i_clk       : in  std_logic;
        i_resetn    : in  std_logic;
        i_start     : in  std_logic;
        i_mode      : in  std_logic;                          -- 0 = step, 1 = mxy (batch)
        i_x1        : in  std_logic_vector(G_M-1 downto 0);
        i_z1        : in  std_logic_vector(G_M-1 downto 0);
        i_x2        : in  std_logic_vector(G_M-1 downto 0);
        i_z2        : in  std_logic_vector(G_M-1 downto 0);
        i_xb        : in  std_logic_vector(G_M-1 downto 0);   -- x of the base point P
        i_yb        : in  std_logic_vector(G_M-1 downto 0);   -- y of the base point P (mode 1)
        i_b         : in  std_logic_vector(G_M-1 downto 0);   -- curve parameter (mode 0)
        o_x1        : out std_logic_vector(G_M-1 downto 0);   -- mode 0: nP1 = 2*P1
        o_z1        : out std_logic_vector(G_M-1 downto 0);
        o_x2        : out std_logic_vector(G_M-1 downto 0);   -- mode 0: nP2 = P1+P2
        o_z2        : out std_logic_vector(G_M-1 downto 0);
        o_x         : out std_logic_vector(G_M-1 downto 0);   -- mode 1: affine x
        o_y         : out std_logic_vector(G_M-1 downto 0);   -- mode 1: affine y
        o_busy      : out std_logic;
        o_done      : out std_logic;
        -- ALU-client bus
        o_alu_start : out std_logic;
        o_alu_op    : out alu_op_t;
        o_alu_a     : out std_logic_vector(G_M-1 downto 0);
        o_alu_b     : out std_logic_vector(G_M-1 downto 0);
        i_alu_busy  : in  std_logic;
        i_alu_done  : in  std_logic;
        i_alu_res   : in  std_logic_vector(G_M-1 downto 0)
    );
end entity;


architecture rtl of ec_step_mxy is

    constant c_MAX_OPS : integer := 18;   -- widest microprogram (mode 1)

    type state_t is (S_IDLE, S_ISSUE, S_WAIT, S_DONE);
    signal state_reg, next_state : state_t := S_IDLE;

    -- Registered state: only scratch + results (inputs are read straight from the
    -- ports, held stable by the parent).
    signal r_t1, r_t2, r_t3 : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- shared scratch
    signal r_t4, r_t5       : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- mode-1 scratch (inverses)
    signal r_nx1, r_nz1     : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- mode0: nP1 ; mode1: x, y
    signal r_nx2, r_nz2     : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- mode0: nP2

    signal r_pc      : unsigned(num_bits(c_MAX_OPS)-1 downto 0) := (others => '0');   -- 1..18: 5 bits
    signal w_num_ops : integer range 1 to c_MAX_OPS;

begin

    -- ops in the current microprogram (mode-dependent, combinational from i_mode)
    w_num_ops <= 14 when i_mode = '0' else 18;

    -- Result outputs. mode 0 uses o_x1..o_z2; mode 1 uses o_x,o_y (= nX1,nZ1 regs).
    o_x1 <= r_nx1;
    o_z1 <= r_nz1;
    o_x2 <= r_nx2;
    o_z2 <= r_nz2;
    o_x  <= r_nx1;
    o_y  <= r_nz1;

    o_busy <= '0' when state_reg = S_IDLE else '1';
    o_done <= '1' when state_reg = S_DONE else '0';
    o_alu_start <= '1' when (state_reg = S_ISSUE and i_alu_busy = '0') else '0';

    ----------------------------------------------------------------------------
    -- Microprogram (op/a/b), selected by i_mode then r_pc. Inputs read directly
    -- from the ports (stable). mode 0 = ec_point_step table; mode 1 = batch mxy.
    ----------------------------------------------------------------------------
    p_ALU_OPS : process(all)
    begin
        o_alu_op <= ALU_ADD;          -- default (outside rows the ALU is not listening)
        o_alu_a  <= r_t1;
        o_alu_b  <= r_t2;

        if i_mode = '0' then
            -- ================= STEP (madd + mdouble) =================
            case to_integer(r_pc) is
                when 1  => o_alu_op <= ALU_MUL; o_alu_a <= i_x2; o_alu_b <= i_z1;   -- T1 = X2*Z1
                when 2  => o_alu_op <= ALU_MUL; o_alu_a <= i_x1; o_alu_b <= i_z2;   -- T2 = X1*Z2
                when 3  => o_alu_op <= ALU_ADD; o_alu_a <= r_t1; o_alu_b <= r_t2;   -- T3 = T1+T2
                when 4  => o_alu_op <= ALU_SQR; o_alu_a <= r_t3;                    -- nZ2 = T3^2
                when 5  => o_alu_op <= ALU_MUL; o_alu_a <= r_t1; o_alu_b <= r_t2;   -- T3 = T1*T2
                when 6  => o_alu_op <= ALU_MUL; o_alu_a <= i_xb; o_alu_b <= r_nz2;  -- T1 = xb*nZ2
                when 7  => o_alu_op <= ALU_ADD; o_alu_a <= r_t1; o_alu_b <= r_t3;   -- nX2 = T1+T3
                when 8  => o_alu_op <= ALU_SQR; o_alu_a <= i_x1;                    -- T1 = X1^2
                when 9  => o_alu_op <= ALU_SQR; o_alu_a <= i_z1;                    -- T2 = Z1^2
                when 10 => o_alu_op <= ALU_MUL; o_alu_a <= r_t1; o_alu_b <= r_t2;   -- nZ1 = X1^2*Z1^2
                when 11 => o_alu_op <= ALU_SQR; o_alu_a <= r_t1;                    -- T1 = X1^4
                when 12 => o_alu_op <= ALU_SQR; o_alu_a <= r_t2;                    -- T2 = Z1^4
                when 13 => o_alu_op <= ALU_MUL; o_alu_a <= i_b;  o_alu_b <= r_t2;   -- T2 = b*Z1^4
                when 14 => o_alu_op <= ALU_ADD; o_alu_a <= r_t1; o_alu_b <= r_t2;   -- nX1 = X1^4+b*Z1^4
                when others => null;
            end case;
        else
            -- ================= MXY (batch inversion) =================
            case to_integer(r_pc) is
                when 1  => o_alu_op <= ALU_MUL; o_alu_a <= i_z1;  o_alu_b <= i_z2;  -- p2 = Z1*Z2
                when 2  => o_alu_op <= ALU_MUL; o_alu_a <= r_t1;  o_alu_b <= i_xb;  -- p3 = p2*xb
                when 3  => o_alu_op <= ALU_INV; o_alu_a <= r_t2;                    -- t  = p3^-1
                when 4  => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= r_t1;  -- xb^-1 = t*p2
                when 5  => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= i_xb;  -- t = t*xb -> (Z1*Z2)^-1
                when 6  => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= i_z1;  -- Z2^-1 = t*Z1
                when 7  => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= i_z2;  -- Z1^-1 = t*Z2
                when 8  => o_alu_op <= ALU_MUL; o_alu_a <= i_x1;  o_alu_b <= r_t5;  -- x1 = X1*Z1^-1  (affine x)
                when 9  => o_alu_op <= ALU_MUL; o_alu_a <= i_x2;  o_alu_b <= r_t4;  -- x2 = X2*Z2^-1
                when 10 => o_alu_op <= ALU_ADD; o_alu_a <= r_nx1; o_alu_b <= i_xb;  -- step1 = x1 + xb
                when 11 => o_alu_op <= ALU_ADD; o_alu_a <= r_t1;  o_alu_b <= i_xb;  -- x2 + xb
                when 12 => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= r_t1;  -- step2 = step1*(x2+xb)
                when 13 => o_alu_op <= ALU_SQR; o_alu_a <= i_xb;                    -- xb^2
                when 14 => o_alu_op <= ALU_ADD; o_alu_a <= r_t1;  o_alu_b <= r_t4;  -- step2 + xb^2
                when 15 => o_alu_op <= ALU_ADD; o_alu_a <= r_t1;  o_alu_b <= i_yb;  -- step3 = ... + yb
                when 16 => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= r_t1;  -- step1 * step3
                when 17 => o_alu_op <= ALU_MUL; o_alu_a <= r_t1;  o_alu_b <= r_t3;  -- step4 = ... * xb^-1
                when 18 => o_alu_op <= ALU_ADD; o_alu_a <= r_t1;  o_alu_b <= i_yb;  -- y1 = step4 + yb
                when others => null;
            end case;
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
    -- FSM next state (combinational) — identical discipline to ec_point_step/ec_mxy
    ----------------------------------------------------------------------------
    p_NEXT_STATE : process(all)
    begin
        next_state <= state_reg;

        case state_reg is

            when S_IDLE =>
                if i_start = '1' then
                    next_state <= S_WAIT;
                end if;

            when S_ISSUE =>
                if i_alu_busy = '1' then
                    next_state <= S_WAIT;
                end if;

            when S_WAIT =>
                if i_alu_done = '1' and r_pc = w_num_ops then
                    next_state <= S_DONE;
                elsif i_alu_busy = '0' then
                    next_state <= S_ISSUE;
                end if;

            when S_DONE =>
                next_state <= S_IDLE;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- pc: 1 on start, advances once per operation (on the done pulse)
    ----------------------------------------------------------------------------
    p_PC : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_pc <= (others => '0');
            else
                case state_reg is
                    when S_IDLE =>
                        if i_start = '1' then
                            r_pc <= to_unsigned(1, r_pc'length);
                        end if;
                    when S_WAIT =>
                        if i_alu_done = '1' then
                            r_pc <= r_pc + 1;
                        end if;
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Datapath: result capture per (mode, pc) dst column. No input snapshot.
    ----------------------------------------------------------------------------
    p_DATAPATH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_t1 <= (others => '0');
                r_t2 <= (others => '0');
                r_t3 <= (others => '0');
                r_t4 <= (others => '0');
                r_t5 <= (others => '0');
                r_nx1 <= (others => '0');
                r_nz1 <= (others => '0');
                r_nx2 <= (others => '0');
                r_nz2 <= (others => '0');
            else
                if i_alu_done = '1' then
                    if i_mode = '0' then
                        case to_integer(r_pc) is       -- STEP dst
                            when 1      => r_t1  <= i_alu_res;
                            when 2      => r_t2  <= i_alu_res;
                            when 3      => r_t3  <= i_alu_res;
                            when 4      => r_nz2 <= i_alu_res;
                            when 5      => r_t3  <= i_alu_res;
                            when 6      => r_t1  <= i_alu_res;
                            when 7      => r_nx2 <= i_alu_res;
                            when 8      => r_t1  <= i_alu_res;
                            when 9      => r_t2  <= i_alu_res;
                            when 10     => r_nz1 <= i_alu_res;
                            when 11     => r_t1  <= i_alu_res;
                            when 12     => r_t2  <= i_alu_res;
                            when 13     => r_t2  <= i_alu_res;
                            when 14     => r_nx1 <= i_alu_res;
                            when others => null;
                        end case;
                    else
                        case to_integer(r_pc) is       -- MXY (batch) dst
                            when 1      => r_t1  <= i_alu_res;   -- p2
                            when 2      => r_t2  <= i_alu_res;   -- p3
                            when 3      => r_t2  <= i_alu_res;   -- t = p3^-1
                            when 4      => r_t3  <= i_alu_res;   -- xb^-1
                            when 5      => r_t2  <= i_alu_res;   -- t = (Z1*Z2)^-1
                            when 6      => r_t4  <= i_alu_res;   -- Z2^-1
                            when 7      => r_t5  <= i_alu_res;   -- Z1^-1
                            when 8      => r_nx1 <= i_alu_res;   -- x1 (affine x)
                            when 9      => r_t1  <= i_alu_res;   -- x2
                            when 10     => r_t2  <= i_alu_res;   -- step1
                            when 11     => r_t1  <= i_alu_res;   -- x2+xb
                            when 12     => r_t1  <= i_alu_res;   -- step2
                            when 13     => r_t4  <= i_alu_res;   -- xb^2
                            when 14     => r_t1  <= i_alu_res;   -- step2+xb^2
                            when 15     => r_t1  <= i_alu_res;   -- step3
                            when 16     => r_t1  <= i_alu_res;   -- step1*step3
                            when 17     => r_t1  <= i_alu_res;   -- step4
                            when 18     => r_nz1 <= i_alu_res;   -- y1
                            when others => null;
                        end case;
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture;
