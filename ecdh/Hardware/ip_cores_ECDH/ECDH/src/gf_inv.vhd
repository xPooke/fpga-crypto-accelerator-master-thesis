----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : gf_inv
-- Module Name   : gf_inv - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : GF(2^m) inversion, Itoh-Tsujii (binary method).
--                 a^-1 = (a^(2^(m-1)-1))^2 = (beta_n)^2, n = m-1; beta_t =
--                 a^(2^t-1) (exponent = t ones). The run of n ones is built by
--                 reading the bits of n: DOUBLE (beta^(2^t) * beta, i.e.
--                 * saved) always, then "+1" (beta^2 * a) when the bit is 1;
--                 finally one squaring. Cost: m-1 squarings (always),
--                 ~13 multiplies for B-571.
--
-- Dependencies  : work.gf_alu_pkg (num_bits), work.gf_sqr
--
-- Revision      :
--   0.01 - June 2026 - File Created
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). gf_sqr is instantiated privately
--   (cheap, one squaring per clock in a loop with r_beta). gf_mul is NOT
--   instantiated but SHARED: gf_inv is a mul-client (o_mul_*/i_mul_*); start
--   is gated on i_mul_busy. a = 0 has no inverse (handled by a higher layer).
--   FSM diagram: gf_inv_fsm.svg.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.gf_alu_pkg.all;

entity gf_inv is
    generic (
        G_M : integer := 4;
        G_F : std_logic_vector := "10011"   -- f WITH the leading bit (G_M+1 bits)
    );
    port (
        i_clk   : in  std_logic;
        i_resetn : in  std_logic;
        i_start : in  std_logic;
        i_a     : in  std_logic_vector(G_M-1 downto 0);
        o_res   : out std_logic_vector(G_M-1 downto 0);
        o_busy  : out std_logic;
        o_done  : out std_logic;

        -- mul-client bus - the ALU connects this to the single shared gf_mul
        o_mul_start : out std_logic;
        o_mul_a     : out std_logic_vector(G_M-1 downto 0);
        o_mul_b     : out std_logic_vector(G_M-1 downto 0);
        i_mul_busy  : in  std_logic;        -- do not start while 1 (handshake)
        i_mul_done  : in  std_logic;
        i_mul_res   : in  std_logic_vector(G_M-1 downto 0)
    );
end entity;


architecture rtl of gf_inv is

    ----------------------------------------------------------------------------
    -- Derived constants (from G_M)
    ----------------------------------------------------------------------------
    constant c_N       : integer := G_M - 1;            -- exponent n = m-1: 3
    constant c_NUMBITS : integer := num_bits(c_N);      -- width of t counter: 2
    constant c_NVEC    : std_logic_vector(c_NUMBITS-1 downto 0)
                         := std_logic_vector(to_unsigned(c_N, c_NUMBITS));
                         -- n as a bit vector (MSB is the implicit start t=1)
    constant c_MSBIDX  : integer := c_NUMBITS - 2;      -- first bit BELOW the MSB (-1 for m=2)

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_DBL_SQ, S_DBL_MUL, S_P1_SQ, S_P1_MUL,
                     S_NEXT, S_FIN, S_DONE);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Datapath registers
    ----------------------------------------------------------------------------
    signal r_beta         : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- current beta
    signal r_a            : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- original a (for "+1")
    signal r_saved        : std_logic_vector(G_M-1 downto 0) := (others => '0');  -- beta before DOUBLE
    signal r_t            : unsigned(c_NUMBITS-1 downto 0) := to_unsigned(1, c_NUMBITS);  -- current t
    signal r_sqcnt        : unsigned(c_NUMBITS-1 downto 0) := (others => '0');    -- squarings remaining
    signal r_bitidx       : integer range -1 to c_NUMBITS-1 := -1;                -- which bit of n is processed
    signal r_mul_launched : std_logic := '0';                                     -- start already sent for this multiply

    ----------------------------------------------------------------------------
    -- Combinational signals
    ----------------------------------------------------------------------------
    signal w_sqr_out : std_logic_vector(G_M-1 downto 0);   -- gf_sqr(r_beta)
    signal w_idx     : integer range 0 to c_NUMBITS-1;     -- guarded index into c_NVEC
    signal w_cur_bit : std_logic;                          -- c_NVEC(r_bitidx)

begin

    assert G_F'length = G_M + 1
        report "G_F must be the irreducible polynomial WITH its leading bit (G_M+1 bits)"
        severity failure;

    assert G_M >= 2
        report "G_M must be >= 2 (n = m-1 needs at least one exponent bit)"
        severity failure;

    ----------------------------------------------------------------------------
    -- Private squarer instance (combinational, in a loop with r_beta)
    ----------------------------------------------------------------------------
    u_sqr : entity work.gf_sqr
        generic map (
            G_M => G_M,
            G_F => G_F
        )
        port map (
            i_a  => r_beta,
            o_sq => w_sqr_out
        );

    -- current bit of n (guard keeps the index from ever reaching -1)
    w_idx     <= r_bitidx when r_bitidx >= 0 else 0;
    w_cur_bit <= c_NVEC(w_idx);

    -- shared-multiplier outputs (o_mul_b mux: r_a in "+1", r_saved otherwise)
    o_mul_a <= r_beta;
    o_mul_b <= r_a when state_reg = S_P1_MUL else r_saved;
    -- start only in MUL states, not sent yet, and only while the multiplier is idle
    o_mul_start <= '1' when ((state_reg = S_DBL_MUL or state_reg = S_P1_MUL)
                             and r_mul_launched = '0' and i_mul_busy = '0') else '0';

    -- status outputs
    o_res  <= r_beta;
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
                    if c_MSBIDX < 0 then       -- n = 1 (m=2): no bits below the MSB
                        next_state <= S_FIN;
                    else
                        next_state <= S_DBL_SQ;
                    end if;
                end if;

            when S_DBL_SQ =>                    -- t squarings; leave on the last one
                if r_sqcnt = 1 then
                    next_state <= S_DBL_MUL;
                end if;

            when S_DBL_MUL =>                   -- wait for the multiplier
                if i_mul_done = '1' then
                    if w_cur_bit = '1' then
                        next_state <= S_P1_SQ;
                    else
                        next_state <= S_NEXT;
                    end if;
                end if;

            when S_P1_SQ =>
                next_state <= S_P1_MUL;

            when S_P1_MUL =>                    -- wait for the multiplier
                if i_mul_done = '1' then
                    next_state <= S_NEXT;
                end if;

            when S_NEXT =>
                if r_bitidx = 0 then
                    next_state <= S_FIN;
                else
                    next_state <= S_DBL_SQ;
                end if;

            when S_FIN =>
                next_state <= S_DONE;

            when S_DONE =>
                next_state <= S_IDLE;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Datapath (registers + counters + launched flag)
    ----------------------------------------------------------------------------
    p_DATAPATH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_beta         <= (others => '0');
                r_a            <= (others => '0');
                r_saved        <= (others => '0');
                r_t            <= to_unsigned(1, c_NUMBITS);
                r_sqcnt        <= (others => '0');
                r_bitidx       <= -1;
                r_mul_launched <= '0';
            else
                case state_reg is

                    when S_IDLE =>
                        if i_start = '1' then
                            r_beta   <= i_a;             -- beta_1 = a
                            r_a      <= i_a;             -- original a (for "+1")
                            r_saved  <= i_a;             -- first DOUBLE multiplies by a (=beta_1)
                            r_t      <= to_unsigned(1, c_NUMBITS);
                            r_sqcnt  <= to_unsigned(1, c_NUMBITS);  -- t=1 squaring
                            r_bitidx <= c_MSBIDX;
                            r_mul_launched <= '0';
                        end if;

                    when S_DBL_SQ =>                     -- multi-squaring: one per clock
                        r_beta  <= w_sqr_out;
                        r_sqcnt <= r_sqcnt - 1;
                        if r_sqcnt = 1 then              -- entering DOUBLE-mul: arm the start
                            r_mul_launched <= '0';
                        end if;

                    when S_DBL_MUL =>                    -- (beta)^(2^t) * saved
                        if r_mul_launched = '0' and i_mul_busy = '0' then
                            r_mul_launched <= '1';       -- start was just sent
                        end if;
                        if i_mul_done = '1' then
                            r_beta <= i_mul_res;
                            r_t    <= r_t sll 1;         -- t -> 2t
                        end if;

                    when S_P1_SQ =>                      -- (beta)^2, entering the "+1" mul
                        r_beta         <= w_sqr_out;
                        r_mul_launched <= '0';

                    when S_P1_MUL =>                     -- (beta)^2 * a
                        if r_mul_launched = '0' and i_mul_busy = '0' then
                            r_mul_launched <= '1';
                        end if;
                        if i_mul_done = '1' then
                            r_beta <= i_mul_res;
                            r_t    <= r_t + 1;           -- t -> t+1
                        end if;

                    when S_NEXT =>                       -- next bit / prepare DOUBLE
                        if r_bitidx /= 0 then
                            r_bitidx <= r_bitidx - 1;
                            r_saved  <= r_beta;          -- saved for the next DOUBLE
                            r_sqcnt  <= r_t;             -- squaring count = current t
                        end if;

                    when S_FIN =>                        -- final squaring -> a^-1
                        r_beta <= w_sqr_out;

                    when S_DONE =>
                        null;

                end case;
            end if;
        end if;
    end process;

end architecture;
