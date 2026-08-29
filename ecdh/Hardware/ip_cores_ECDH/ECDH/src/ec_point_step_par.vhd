----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ec_point_step_par
-- Module Name   : ec_point_step_par - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Phase-2 (minimum-latency) variant of ec_point_step. Same FIXED
--                 Montgomery ladder step (post-cswap), bit-identical to
--                 ec_point_step, but owns THREE gf_mul instances and runs the six
--                 multiplications as two parallel rounds, with squarings/additions
--                 as local combinational networks (gf_sqr + xor):
--                   Round 1 (3 mul):  M1 =X2*Z1  ‖ M2 =X1*Z2  ‖ M10=X1^2*Z1^2
--                   Round 2 (3 mul):  M5 =T1*T2  ‖ M6 =xb*nZ2 ‖ M13=b*Z1^4
--                 Dependency depth 2 -> two rounds is the floor; three multipliers
--                 fill both rounds with no idle lane. b stays a runtime input.
--
-- Dependencies  : work.gf_mul (digit-serial multiplier), work.gf_sqr (combinational)
--
-- Revision      :
--   0.01 - August 2026 - File Created
--   0.02 - August 2026 - Dropped the input snapshot (i_x1..i_b are only READ):
--                        reads the ports directly, saving 6 words (~3.4k FF).
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). NO input snapshot: i_x1,i_z1,i_x2,
--   i_z2,i_xb,i_b must be held STABLE by the parent for the whole step (they are
--   never registered here). The parent ec_scalar_mult_par guarantees this (ladder
--   state updates only on this module's o_done). Registered state is only the
--   captured multiplier results (r_m1,r_m2,r_m10,r_m5,r_m6,r_m13). The three
--   multipliers are identical (same G_D), started together, finished together;
--   the FSM waits on the AND of their done pulses. Start is a 1-clock strobe.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity ec_point_step_par is
    generic (
        G_M : integer := 4;
        G_D : integer := 1;                 -- multiplier digit width (bits/clock)
        G_F : std_logic_vector := "10011"   -- f WITH the leading bit (G_M+1 bits)
    );
    port (
        i_clk    : in  std_logic;
        i_resetn : in  std_logic;
        i_start  : in  std_logic;
        i_x1     : in  std_logic_vector(G_M-1 downto 0);
        i_z1     : in  std_logic_vector(G_M-1 downto 0);
        i_x2     : in  std_logic_vector(G_M-1 downto 0);
        i_z2     : in  std_logic_vector(G_M-1 downto 0);
        i_xb     : in  std_logic_vector(G_M-1 downto 0);  -- x of the base point P
        i_b      : in  std_logic_vector(G_M-1 downto 0);  -- curve parameter b
        o_x1     : out std_logic_vector(G_M-1 downto 0);  -- nP1 = 2*P1
        o_z1     : out std_logic_vector(G_M-1 downto 0);
        o_x2     : out std_logic_vector(G_M-1 downto 0);  -- nP2 = P1+P2
        o_z2     : out std_logic_vector(G_M-1 downto 0);
        o_busy   : out std_logic;
        o_done   : out std_logic
    );
end entity;


architecture rtl of ec_point_step_par is

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_R1_ISSUE, S_R1_WAIT, S_R2_ISSUE, S_R2_WAIT, S_DONE);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Captured multiplier results (only registered state; inputs are read from
    -- the ports, held stable by the parent)
    ----------------------------------------------------------------------------
    signal r_m1, r_m2, r_m10 : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- round 1
    signal r_m5, r_m6, r_m13 : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- round 2

    ----------------------------------------------------------------------------
    -- Local combinational networks (squares fed straight from the input ports)
    ----------------------------------------------------------------------------
    signal w_x1sq, w_x1_4 : std_logic_vector(G_M-1 downto 0);  -- X1^2, X1^4
    signal w_z1sq, w_z1_4 : std_logic_vector(G_M-1 downto 0);  -- Z1^2, Z1^4
    signal w_t1t2         : std_logic_vector(G_M-1 downto 0);  -- T1+T2 = M1 xor M2
    signal w_nz2          : std_logic_vector(G_M-1 downto 0);  -- (T1+T2)^2

    ----------------------------------------------------------------------------
    -- Multiplier bus (3 lanes)
    ----------------------------------------------------------------------------
    signal w_mul_start                : std_logic;
    signal w_a0, w_b0, w_a1, w_b1, w_a2, w_b2 : std_logic_vector(G_M-1 downto 0);
    signal w_r0, w_r1, w_r2           : std_logic_vector(G_M-1 downto 0);
    signal w_busy0, w_busy1, w_busy2  : std_logic;
    signal w_done0, w_done1, w_done2  : std_logic;
    signal w_all_done                 : std_logic;
    signal w_r2_phase                 : std_logic;   -- '1' while issuing/running round 2

begin

    assert G_F'length = G_M + 1
        report "G_F must be the irreducible polynomial WITH its leading bit (G_M+1 bits)"
        severity failure;

    ----------------------------------------------------------------------------
    -- Local squarers (combinational). X1^4 = (X1^2)^2, Z1^4 = (Z1^2)^2.
    ----------------------------------------------------------------------------
    u_sq_x1 : entity work.gf_sqr
        generic map (
            G_M => G_M,
            G_F => G_F
        )
        port map (
            i_a  => i_x1,
            o_sq => w_x1sq
        );

    u_sq_x14 : entity work.gf_sqr
        generic map (
            G_M => G_M,
            G_F => G_F
        )
        port map (
            i_a  => w_x1sq,
            o_sq => w_x1_4
        );

    u_sq_z1 : entity work.gf_sqr
        generic map (
            G_M => G_M,
            G_F => G_F
        )
        port map (
            i_a  => i_z1,
            o_sq => w_z1sq
        );

    u_sq_z14 : entity work.gf_sqr
        generic map (
            G_M => G_M,
            G_F => G_F
        )
        port map (
            i_a  => w_z1sq,
            o_sq => w_z1_4
        );

    -- Field addition is XOR in char 2 — done inline (no gf_add instance needed).
    w_t1t2 <= r_m1 xor r_m2;                                -- gf_add: T1 + T2

    u_sq_nz2 : entity work.gf_sqr
        generic map (
            G_M => G_M,
            G_F => G_F
        )
        port map (
            i_a  => w_t1t2,
            o_sq => w_nz2
        );

    ----------------------------------------------------------------------------
    -- Three multipliers (identical, started together)
    ----------------------------------------------------------------------------
    u_mul0 : entity work.gf_mul
        generic map (
            G_M => G_M,
            G_D => G_D,
            G_F => G_F
        )
        port map (
            i_clk    => i_clk,
            i_resetn => i_resetn,
            i_start  => w_mul_start,
            i_a      => w_a0,
            i_b      => w_b0,
            o_res    => w_r0,
            o_busy   => w_busy0,
            o_done   => w_done0
        );

    u_mul1 : entity work.gf_mul
        generic map (
            G_M => G_M,
            G_D => G_D,
            G_F => G_F
        )
        port map (
            i_clk    => i_clk,
            i_resetn => i_resetn,
            i_start  => w_mul_start,
            i_a      => w_a1,
            i_b      => w_b1,
            o_res    => w_r1,
            o_busy   => w_busy1,
            o_done   => w_done1
        );

    u_mul2 : entity work.gf_mul
        generic map (
            G_M => G_M,
            G_D => G_D,
            G_F => G_F
        )
        port map (
            i_clk    => i_clk,
            i_resetn => i_resetn,
            i_start  => w_mul_start,
            i_a      => w_a2,
            i_b      => w_b2,
            o_res    => w_r2,
            o_busy   => w_busy2,
            o_done   => w_done2
        );

    w_all_done <= w_done0 and w_done1 and w_done2;

    ----------------------------------------------------------------------------
    -- Round selection + operand mux for the three lanes (inputs from the ports)
    --   R1:  lane0 = X2*Z1   lane1 = X1*Z2   lane2 = X1^2*Z1^2
    --   R2:  lane0 = T1*T2    lane1 = xb*nZ2  lane2 = b*Z1^4
    ----------------------------------------------------------------------------
    w_r2_phase <= '1' when (state_reg = S_R2_ISSUE or state_reg = S_R2_WAIT) else '0';

    w_a0 <= r_m1   when w_r2_phase = '1' else i_x2;
    w_b0 <= r_m2   when w_r2_phase = '1' else i_z1;
    w_a1 <= i_xb   when w_r2_phase = '1' else i_x1;
    w_b1 <= w_nz2  when w_r2_phase = '1' else i_z2;
    w_a2 <= i_b    when w_r2_phase = '1' else w_x1sq;
    w_b2 <= w_z1_4 when w_r2_phase = '1' else w_z1sq;

    -- 1-clock start strobe: only in the ISSUE states (multipliers are idle there)
    w_mul_start <= '1' when (state_reg = S_R1_ISSUE or state_reg = S_R2_ISSUE) else '0';

    ----------------------------------------------------------------------------
    -- Status + result outputs
    ----------------------------------------------------------------------------
    o_busy <= '0' when state_reg = S_IDLE else '1';
    o_done <= '1' when state_reg = S_DONE else '0';

    -- Outputs combine captured products with the local squares; inline xor = gf_add.
    o_z1 <= r_m10;                 -- nZ1 = X1^2*Z1^2
    o_x1 <= w_x1_4 xor r_m13;      -- nX1 = X1^4 + b*Z1^4   (xor = gf_add)
    o_z2 <= w_nz2;                 -- nZ2 = (T1+T2)^2
    o_x2 <= r_m5 xor r_m6;         -- nX2 = T1*T2 + xb*nZ2  (xor = gf_add)

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
                    next_state <= S_R1_ISSUE;
                end if;

            when S_R1_ISSUE =>
                next_state <= S_R1_WAIT;           -- strobe lasts exactly 1 clock

            when S_R1_WAIT =>
                if w_all_done = '1' then
                    next_state <= S_R2_ISSUE;
                end if;

            when S_R2_ISSUE =>
                next_state <= S_R2_WAIT;

            when S_R2_WAIT =>
                if w_all_done = '1' then
                    next_state <= S_DONE;
                end if;

            when S_DONE =>
                next_state <= S_IDLE;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Datapath: capture the multiplier results (no input snapshot)
    ----------------------------------------------------------------------------
    p_DATAPATH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_m1  <= (others => '0');
                r_m2  <= (others => '0');
                r_m10 <= (others => '0');
                r_m5  <= (others => '0');
                r_m6  <= (others => '0');
                r_m13 <= (others => '0');
            else
                -- capture round 1 results
                if state_reg = S_R1_WAIT and w_all_done = '1' then
                    r_m1  <= w_r0;   -- T1  = X2*Z1
                    r_m2  <= w_r1;   -- T2  = X1*Z2
                    r_m10 <= w_r2;   -- nZ1 = X1^2*Z1^2
                end if;

                -- capture round 2 results
                if state_reg = S_R2_WAIT and w_all_done = '1' then
                    r_m5  <= w_r0;   -- T1*T2
                    r_m6  <= w_r1;   -- xb*nZ2
                    r_m13 <= w_r2;   -- b*Z1^4
                end if;
            end if;
        end if;
    end process;

end architecture;
