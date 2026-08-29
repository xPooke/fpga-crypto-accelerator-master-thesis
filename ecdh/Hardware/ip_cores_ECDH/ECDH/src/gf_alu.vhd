----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : gf_alu
-- Module Name   : gf_alu - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : GF(2^m) ALU — a pure executor. It receives an operation
--                 (i_op) and operands (i_a, i_b), goes busy on i_start and
--                 pulses o_done with the result on o_res. There is NO register
--                 file (live variables are kept by the client / scalar-mult
--                 layer). Operations: ALU_ADD (xor), ALU_SQR (a^2),
--                 ALU_MUL (a*b), ALU_INV (a^-1).
--
-- Dependencies  : work.gf_alu_pkg, work.gf_add, work.gf_sqr, work.gf_mul,
--                 work.gf_inv
--
-- Revision      :
--   0.01 - June 2026 - File Created
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). A single gf_mul is SHARED between
--   the direct MUL path and gf_inv (bus mux by state: S_INV -> gf_inv drives
--   the multiplier). gf_add/gf_sqr are combinational, private. Starts toward
--   the multiplier/inverter are gated on busy (handshake).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.gf_alu_pkg.all;

entity gf_alu is
    generic (
        G_M : integer := 4;
        G_D : integer := 1;                 -- digit width of gf_mul
        G_F : std_logic_vector := "10011"   -- f WITH the leading bit (G_M+1 bits)
    );
    port (
        i_clk   : in  std_logic;
        i_resetn : in  std_logic;
        i_op    : in  alu_op_t;
        i_start : in  std_logic;
        i_a     : in  std_logic_vector(G_M-1 downto 0);
        i_b     : in  std_logic_vector(G_M-1 downto 0);
        o_res   : out std_logic_vector(G_M-1 downto 0);
        o_busy  : out std_logic;
        o_done  : out std_logic
    );
end entity;


architecture rtl of gf_alu is

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_COMB, S_MUL, S_INV, S_DONE);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Datapath registers
    ----------------------------------------------------------------------------
    signal r_a, r_b, r_res : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- operands + result
    signal r_op            : alu_op_t  := ALU_ADD;   -- latched operation
    signal r_dmul_launched : std_logic := '0';       -- direct MUL: start already sent
    signal r_inv_launched  : std_logic := '0';       -- INV: start already sent

    ----------------------------------------------------------------------------
    -- Sub-block outputs (combinational / registered inside the sub-blocks)
    ----------------------------------------------------------------------------
    signal w_add_out, w_sqr_out   : std_logic_vector(G_M-1 downto 0);  -- gf_add / gf_sqr
    signal w_mul_out, w_inv_out   : std_logic_vector(G_M-1 downto 0);  -- gf_mul / gf_inv
    signal w_mul_busy, w_mul_done : std_logic;
    signal w_inv_busy, w_inv_done : std_logic;

    ----------------------------------------------------------------------------
    -- Shared-multiplier bus
    ----------------------------------------------------------------------------
    signal w_inv_mul_start          : std_logic;                         -- gf_inv mul-client
    signal w_inv_mul_a, w_inv_mul_b : std_logic_vector(G_M-1 downto 0);
    signal w_mul_start              : std_logic;                         -- mux: direct vs inv
    signal w_mul_a, w_mul_b         : std_logic_vector(G_M-1 downto 0);
    signal w_direct_mul_start       : std_logic;                         -- strobe for the direct MUL
    signal w_inv_start              : std_logic;                         -- strobe for gf_inv

begin

    assert G_F'length = G_M + 1
        report "G_F must be the irreducible polynomial WITH its leading bit (G_M+1 bits)"
        severity failure;

    ----------------------------------------------------------------------------
    -- Combinational blocks (private, cheap)
    ----------------------------------------------------------------------------
    u_add : entity work.gf_add
        generic map (
            G_M => G_M
        )
        port map (
            i_a   => r_a,
            i_b   => r_b,
            o_sum => w_add_out
        );

    u_sqr : entity work.gf_sqr
        generic map (
            G_M => G_M,
            G_F => G_F
        )
        port map (
            i_a  => r_a,
            o_sq => w_sqr_out
        );

    ----------------------------------------------------------------------------
    -- Shared multiplier + inversion (mul-client)
    ----------------------------------------------------------------------------
    u_mul : entity work.gf_mul
        generic map (
            G_M => G_M,
            G_D => G_D,
            G_F => G_F
        )
        port map (
            i_clk    => i_clk,
            i_resetn => i_resetn,
            i_start  => w_mul_start,
            i_a      => w_mul_a,
            i_b      => w_mul_b,
            o_res    => w_mul_out,
            o_busy   => w_mul_busy,
            o_done   => w_mul_done
        );

    u_inv : entity work.gf_inv
        generic map (
            G_M => G_M,
            G_F => G_F
        )
        port map (
            i_clk       => i_clk,
            i_resetn    => i_resetn,
            i_start     => w_inv_start,
            i_a         => r_a,
            o_res       => w_inv_out,
            o_busy      => w_inv_busy,
            o_done      => w_inv_done,
            o_mul_start => w_inv_mul_start,
            o_mul_a     => w_inv_mul_a,
            o_mul_b     => w_inv_mul_b,
            i_mul_busy  => w_mul_busy,
            i_mul_done  => w_mul_done,
            i_mul_res   => w_mul_out
        );

    ----------------------------------------------------------------------------
    -- Shared-multiplier arbiter: in S_INV gf_inv drives it, the direct MUL
    -- path otherwise
    ----------------------------------------------------------------------------
    w_mul_start <= w_inv_mul_start when state_reg = S_INV else w_direct_mul_start;
    w_mul_a     <= w_inv_mul_a     when state_reg = S_INV else r_a;
    w_mul_b     <= w_inv_mul_b     when state_reg = S_INV else r_b;

    -- 1-clock strobes, gated on busy (handshake)
    w_direct_mul_start <= '1' when (state_reg = S_MUL and r_dmul_launched = '0'
                                    and w_mul_busy = '0') else '0';
    w_inv_start        <= '1' when (state_reg = S_INV and r_inv_launched = '0'
                                    and w_inv_busy = '0') else '0';

    ----------------------------------------------------------------------------
    -- Status outputs
    ----------------------------------------------------------------------------
    o_res  <= r_res;
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
                    case i_op is
                        when ALU_ADD | ALU_SQR => next_state <= S_COMB;
                        when ALU_MUL           => next_state <= S_MUL;
                        when ALU_INV           => next_state <= S_INV;
                    end case;
                end if;

            when S_COMB =>                      -- add/sqr: combinational result (1 clock)
                next_state <= S_DONE;

            when S_MUL =>
                if w_mul_done = '1' then
                    next_state <= S_DONE;
                end if;

            when S_INV =>
                if w_inv_done = '1' then
                    next_state <= S_DONE;
                end if;

            when S_DONE =>
                next_state <= S_IDLE;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Datapath (operands, result, launched flags)
    ----------------------------------------------------------------------------
    p_DATAPATH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_a             <= (others => '0');
                r_b             <= (others => '0');
                r_res           <= (others => '0');
                r_op            <= ALU_ADD;
                r_dmul_launched <= '0';
                r_inv_launched  <= '0';
            else
                case state_reg is

                    when S_IDLE =>
                        if i_start = '1' then
                            r_a  <= i_a;
                            r_b  <= i_b;
                            r_op <= i_op;
                            r_dmul_launched <= '0';
                            r_inv_launched  <= '0';
                        end if;

                    when S_COMB =>                  -- add/sqr result
                        if r_op = ALU_ADD then
                            r_res <= w_add_out;
                        else
                            r_res <= w_sqr_out;
                        end if;

                    when S_MUL =>
                        if r_dmul_launched = '0' and w_mul_busy = '0' then
                            r_dmul_launched <= '1';
                        end if;
                        if w_mul_done = '1' then
                            r_res <= w_mul_out;
                        end if;

                    when S_INV =>
                        if r_inv_launched = '0' and w_inv_busy = '0' then
                            r_inv_launched <= '1';
                        end if;
                        if w_inv_done = '1' then
                            r_res <= w_inv_out;
                        end if;

                    when S_DONE =>
                        null;

                end case;
            end if;
        end if;
    end process;

end architecture;
