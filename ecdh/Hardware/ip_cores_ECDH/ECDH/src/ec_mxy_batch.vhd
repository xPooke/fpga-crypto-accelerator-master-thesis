----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ec_mxy_batch
-- Module Name   : ec_mxy_batch - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Phase-2 y-recovery with Montgomery BATCH (simultaneous)
--                 inversion. Same function/interface as ec_mxy (from ladder state
--                 (X1,Z1,X2,Z2) and base (xb,yb) -> affine (x,y)), but the three
--                 field inversions Z1^-1, Z2^-1, xb^-1 (independent) are computed
--                 with ONE inversion + 6 multiplications instead of 3 inversions:
--                   p2=Z1*Z2 ; p3=p2*xb ; t=p3^-1 ;
--                   xb^-1=t*p2 ; t=t*xb ; Z2^-1=t*Z1 ; t=t*Z2 ; Z1^-1=t
--                 Inversion is squaring-bound (~m-1 squarings), so trading 2 INV
--                 for 6 MUL saves ~2 INV worth of cycles per k*P. Rest of the Mxy
--                 formula is identical to ec_mxy. ALU client, 18-op microprogram
--                 (11 MUL + 1 INV + 1 SQR + 5 ADD). Golden: Mxy in ec_ladder.py.
--
-- Dependencies  : work.gf_alu_pkg (alu_op_t, num_bits); connects to work.gf_alu
--
-- Revision      :
--   0.01 - August 2026 - File Created
--   0.02 - August 2026 - Dropped the input snapshot (i_x1..i_yb are only READ):
--                        reads the ports directly, saving 6 words (~3.4k FF).
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). NO input snapshot: i_x1,i_z1,i_x2,
--   i_z2,i_xb,i_yb must be held STABLE by the parent for the whole operation (they
--   are never registered here). The parent ecdh_core_low_latency guarantees this (the
--   ladder result is held after the ladder finishes). Registered state is only the
--   scratch (r_t1..r_t5) and results (r_rx,r_ry). Preconditions: xb,Z1,Z2 /= 0.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.gf_alu_pkg.all;

entity ec_mxy_batch is
    generic (
        G_M : integer := 4
    );
    port (
        i_clk       : in  std_logic;
        i_resetn    : in  std_logic;
        i_start     : in  std_logic;
        i_x1        : in  std_logic_vector(G_M-1 downto 0);  -- ladder state
        i_z1        : in  std_logic_vector(G_M-1 downto 0);
        i_x2        : in  std_logic_vector(G_M-1 downto 0);
        i_z2        : in  std_logic_vector(G_M-1 downto 0);
        i_xb        : in  std_logic_vector(G_M-1 downto 0);  -- x of the base point P
        i_yb        : in  std_logic_vector(G_M-1 downto 0);  -- y of the base point P
        o_x         : out std_logic_vector(G_M-1 downto 0);  -- affine x of k*P
        o_y         : out std_logic_vector(G_M-1 downto 0);  -- affine y of k*P
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


architecture rtl of ec_mxy_batch is

    constant c_NUM_OPS : integer := 18;   -- microprogram rows

    type state_t is (S_IDLE, S_ISSUE, S_WAIT, S_DONE);
    signal state_reg, next_state : state_t := S_IDLE;

    -- Registered state: only scratch + results (inputs read from the ports).
    signal r_t1, r_t2, r_t3 : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- scratch
    signal r_t4, r_t5       : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- 3 inverses live
    signal r_rx, r_ry       : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- result (x, y)

    signal r_pc : unsigned(num_bits(c_NUM_OPS)-1 downto 0) := (others => '0');
                  -- operation counter, 1..18: 5 bits

begin

    o_x <= r_rx;
    o_y <= r_ry;
    o_busy <= '0' when state_reg = S_IDLE else '1';
    o_done <= '1' when state_reg = S_DONE else '0';
    o_alu_start <= '1' when (state_reg = S_ISSUE and i_alu_busy = '0') else '0';

    ----------------------------------------------------------------------------
    -- Microprogram, columns op/a/b (row = r_pc). Inputs read directly from the
    -- ports. Register map:
    --   batch:  r_t1=p2, r_t2=p3->t, r_t3=xb^-1, r_t4=Z2^-1, r_t5=Z1^-1
    --   formula reuses r_t1/r_t2/r_t4 after the inverses are consumed.
    ----------------------------------------------------------------------------
    p_ALU_OPS : process(all)
    begin
        o_alu_op <= ALU_ADD;   -- default (outside rows 1..18 the ALU is not listening)
        o_alu_a  <= r_t1;
        o_alu_b  <= r_t2;

        case to_integer(r_pc) is
            -- batch inversion of {Z1, Z2, xb}
            when 1  => o_alu_op <= ALU_MUL; o_alu_a <= i_z1;  o_alu_b <= i_z2;   -- p2 = Z1*Z2
            when 2  => o_alu_op <= ALU_MUL; o_alu_a <= r_t1;  o_alu_b <= i_xb;   -- p3 = p2*xb
            when 3  => o_alu_op <= ALU_INV; o_alu_a <= r_t2;                     -- t  = p3^-1
            when 4  => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= r_t1;   -- xb^-1 = t*p2
            when 5  => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= i_xb;   -- t = t*xb  -> (Z1*Z2)^-1
            when 6  => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= i_z1;   -- Z2^-1 = t*Z1
            when 7  => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= i_z2;   -- Z1^-1 = t*Z2
            -- affine conversion + y-recovery (uses the three inverses)
            when 8  => o_alu_op <= ALU_MUL; o_alu_a <= i_x1;  o_alu_b <= r_t5;   -- x1 = X1*Z1^-1  (affine x)
            when 9  => o_alu_op <= ALU_MUL; o_alu_a <= i_x2;  o_alu_b <= r_t4;   -- x2 = X2*Z2^-1
            when 10 => o_alu_op <= ALU_ADD; o_alu_a <= r_rx;  o_alu_b <= i_xb;   -- step1 = x1 + xb
            when 11 => o_alu_op <= ALU_ADD; o_alu_a <= r_t1;  o_alu_b <= i_xb;   -- x2 + xb
            when 12 => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= r_t1;   -- step2 = step1*(x2+xb)
            when 13 => o_alu_op <= ALU_SQR; o_alu_a <= i_xb;                     -- xb^2
            when 14 => o_alu_op <= ALU_ADD; o_alu_a <= r_t1;  o_alu_b <= r_t4;   -- step2 + xb^2
            when 15 => o_alu_op <= ALU_ADD; o_alu_a <= r_t1;  o_alu_b <= i_yb;   -- step3 = ... + yb
            when 16 => o_alu_op <= ALU_MUL; o_alu_a <= r_t2;  o_alu_b <= r_t1;   -- step1 * step3
            when 17 => o_alu_op <= ALU_MUL; o_alu_a <= r_t1;  o_alu_b <= r_t3;   -- step4 = ... * xb^-1
            when 18 => o_alu_op <= ALU_ADD; o_alu_a <= r_t1;  o_alu_b <= i_yb;   -- y1 = step4 + yb
            when others => null;
        end case;
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
    -- FSM next state (combinational) — identical to ec_mxy
    ----------------------------------------------------------------------------
    p_NEXT_STATE : process(all)
    begin
        next_state <= state_reg;

        case state_reg is

            when S_IDLE =>
                if i_start = '1' then
                    next_state <= S_WAIT;   -- ALU idle -> S_WAIT releases row #1 immediately
                end if;

            when S_ISSUE =>
                if i_alu_busy = '1' then
                    next_state <= S_WAIT;
                end if;

            when S_WAIT =>
                if i_alu_done = '1' and r_pc = c_NUM_OPS then
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
    -- Datapath: result capture per the dst column (no input snapshot).
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
                r_rx <= (others => '0');
                r_ry <= (others => '0');
            else
                if i_alu_done = '1' then
                    case to_integer(r_pc) is
                        when 1      => r_t1 <= i_alu_res;   -- p2
                        when 2      => r_t2 <= i_alu_res;   -- p3
                        when 3      => r_t2 <= i_alu_res;   -- t = p3^-1
                        when 4      => r_t3 <= i_alu_res;   -- xb^-1
                        when 5      => r_t2 <= i_alu_res;   -- t = (Z1*Z2)^-1
                        when 6      => r_t4 <= i_alu_res;   -- Z2^-1
                        when 7      => r_t5 <= i_alu_res;   -- Z1^-1
                        when 8      => r_rx <= i_alu_res;   -- x1 (affine x)
                        when 9      => r_t1 <= i_alu_res;   -- x2
                        when 10     => r_t2 <= i_alu_res;   -- step1
                        when 11     => r_t1 <= i_alu_res;   -- x2+xb
                        when 12     => r_t1 <= i_alu_res;   -- step2
                        when 13     => r_t4 <= i_alu_res;   -- xb^2
                        when 14     => r_t1 <= i_alu_res;   -- step2+xb^2
                        when 15     => r_t1 <= i_alu_res;   -- step3
                        when 16     => r_t1 <= i_alu_res;   -- step1*step3
                        when 17     => r_t1 <= i_alu_res;   -- step4
                        when 18     => r_ry <= i_alu_res;   -- y1
                        when others => null;
                    end case;
                end if;
            end if;
        end if;
    end process;

end architecture;
