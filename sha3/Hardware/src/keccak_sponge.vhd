----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : January 2026
-- Design Name   : keccak_sponge
-- Module Name   : keccak_sponge - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Keccak sponge controller: absorbs rate-sized blocks into
--                 the 1600-bit state, runs the 24 rounds of Keccak-f[1600]
--                 (ROUNDS_PER_CYCLE rounds combinationally per clock), and
--                 squeezes the output as rate-sized chunks. OUT_BITS sets the
--                 total output; when it exceeds the rate (SHAKE XOF), the
--                 state is re-permuted between chunks. The next chunk is
--                 permuted WHILE the output buffer serializes the previous
--                 one. Rounds come from work.keccak_pkg as pure functions.
--
-- Dependencies  : work.keccak_pkg
--
-- Revision      :
--   0.01 - January 2026 - File Created
--
-- Additional Comments :
--   Active-low synchronous reset. ROUNDS_PER_CYCLE must divide 24 (1, 2, 3,
--   4, 6, 8, 12, 24 -- rejected at elaboration otherwise); values above 2
--   give diminishing fmax returns. Permutation latency is 24/ROUNDS_PER_CYCLE
--   cycles per block/chunk. For OUT_BITS <= rate (all SHA3 variants) exactly
--   one chunk is handed over and S_SQUEEZE degenerates to a plain
--   hash-done state. arr_w_round exposes every intermediate round value
--   for waveform inspection.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.keccak_pkg.all;

entity keccak_sponge is
    generic (
        RATE_WORDS       : integer := 34;   -- sponge rate in DATA_WIDTH words
        DATA_WIDTH       : integer := 32;   -- input word width
        OUT_BITS         : integer := 256;  -- total output size in bits
        ROUNDS_PER_CYCLE : integer := 1     -- rounds applied per clock (divisor of 24)
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;                                     -- active low

        -- Block handover from the input buffer
        i_block       : in  std_logic_vector(RATE_WORDS * DATA_WIDTH - 1 downto 0);
        i_block_valid : in  std_logic;
        i_block_last  : in  std_logic;                                     -- block closes the message
        o_block_ready : out std_logic;

        -- Chunk handover to the output buffer (low part of the state)
        o_chunk       : out std_logic_vector(imin(OUT_BITS, RATE_WORDS * DATA_WIDTH) - 1 downto 0);
        o_chunk_valid : out std_logic;
        i_chunk_ready : in  std_logic
    );
end entity;

architecture rtl of keccak_sponge is

    constant c_RATE_BITS  : integer := RATE_WORDS * DATA_WIDTH;
    constant c_ITER_MAX   : integer := c_NUM_ROUNDS / ROUNDS_PER_CYCLE;  -- permutation iterations per block
    constant c_CHUNK_BITS : integer := imin(OUT_BITS, c_RATE_BITS);      -- bits handed over per chunk
    constant c_NUM_CHUNKS : integer := (OUT_BITS + c_RATE_BITS - 1) / c_RATE_BITS;  -- squeeze chunks per message

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_INIT, S_ROUND, S_WAIT, S_SQUEEZE);
    signal state_reg, next_state : state_t;

    ----------------------------------------------------------------------------
    -- Keccak state + round chain
    ----------------------------------------------------------------------------
    type arr_round_t is array (0 to ROUNDS_PER_CYCLE) of keccak_state_t;
    signal arr_w_round : arr_round_t;                          -- (0) = current state, (k) = after k rounds
    signal r_state     : keccak_state_t := (others => '0');    -- registered sponge state

    signal r_iter_cnt   : unsigned(4 downto 0) := (others => '0');       -- permutation iteration counter
    signal r_last_block : std_logic := '0';                              -- absorbed block was the final one
    signal r_chunk_cnt  : integer range 0 to c_NUM_CHUNKS := 0;          -- squeeze chunks already handed over

begin

    assert c_NUM_ROUNDS mod ROUNDS_PER_CYCLE = 0
        report "keccak_sponge: ROUNDS_PER_CYCLE must divide 24"
        severity failure;

    ----------------------------------------------------------------------------
    -- Combinational round chain: ROUNDS_PER_CYCLE rounds per clock
    ----------------------------------------------------------------------------
    arr_w_round(0) <= r_state;

    gen_rounds : for k in 1 to ROUNDS_PER_CYCLE generate
        arr_w_round(k) <= keccak_round(arr_w_round(k - 1),
                                       to_integer(r_iter_cnt) * ROUNDS_PER_CYCLE + k - 1);
    end generate gen_rounds;

    ----------------------------------------------------------------------------
    -- Datapath registers: absorb (XOR into the rate portion) and permute
    ----------------------------------------------------------------------------
    p_STATE : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_iter_cnt   <= (others => '0');
                r_state      <= (others => '0');
                r_last_block <= '0';
            else
                case state_reg is

                    when S_INIT =>
                        r_state      <= (others => '0');
                        r_last_block <= '0';
                        r_chunk_cnt  <= 0;

                        -- First block of a NEW message: absorb into an
                        -- explicitly zero state. The previous message's final
                        -- state may still sit in r_state when back-to-back
                        -- traffic delivers this block on the first S_INIT
                        -- cycle -- XOR-ing into it would corrupt the hash.
                        if i_block_valid = '1' then
                            r_state                                       <= (others => '0');
                            r_state(c_RATE_BITS - 1 downto 0)             <= i_block;
                            if i_block_last = '1' then
                                r_last_block <= '1';
                            end if;
                        end if;

                    when S_WAIT =>
                        if i_block_valid = '1' then
                            r_state <= r_state(c_STATE_BITS - 1 downto c_RATE_BITS) &
                                       (r_state(c_RATE_BITS - 1 downto 0) xor i_block);
                            if i_block_last = '1' then
                                r_last_block <= '1';
                            end if;
                        end if;

                    when S_ROUND =>
                        if r_iter_cnt < c_ITER_MAX - 1 then
                            r_iter_cnt <= r_iter_cnt + 1;
                        end if;
                        r_state <= arr_w_round(ROUNDS_PER_CYCLE);

                    when S_SQUEEZE =>
                        -- Chunk accepted by the output buffer
                        if i_chunk_ready = '1' then
                            r_chunk_cnt <= r_chunk_cnt + 1;
                        end if;

                end case;

                -- Iteration counter only runs inside S_ROUND
                if state_reg /= S_ROUND then
                    r_iter_cnt <= (others => '0');
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM register
    ----------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                state_reg <= S_INIT;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM next-state logic
    ----------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, i_block_valid, i_chunk_ready, r_iter_cnt,
                           r_last_block, r_chunk_cnt)
    begin
        next_state <= state_reg;  -- default: stay

        case state_reg is

            when S_INIT =>
                if i_block_valid = '1' then
                    next_state <= S_ROUND;
                end if;

            when S_ROUND =>
                if r_iter_cnt = c_ITER_MAX - 1 then
                    if r_last_block = '1' then
                        next_state <= S_SQUEEZE;
                    else
                        next_state <= S_WAIT;
                    end if;
                end if;

            when S_WAIT =>
                if i_block_valid = '1' then
                    next_state <= S_ROUND;
                end if;

            when S_SQUEEZE =>
                -- On handover: last chunk -> done; otherwise permute the next
                -- chunk NOW, in parallel with the output buffer serializing
                -- the one it just took
                if i_chunk_ready = '1' then
                    if r_chunk_cnt = c_NUM_CHUNKS - 1 then
                        next_state <= S_INIT;
                    else
                        next_state <= S_ROUND;
                    end if;
                end if;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Moore outputs
    ----------------------------------------------------------------------------
    p_OUTPUTS : process(state_reg, r_state)
    begin
        o_chunk       <= (others => '0');
        o_chunk_valid <= '0';
        o_block_ready <= '0';

        case state_reg is
            when S_INIT =>
                o_block_ready <= '1';
            when S_WAIT =>
                o_block_ready <= '1';
            when S_SQUEEZE =>
                o_chunk       <= r_state(c_CHUNK_BITS - 1 downto 0);
                o_chunk_valid <= '1';
            when others =>
                null;
        end case;
    end process;

end architecture;
