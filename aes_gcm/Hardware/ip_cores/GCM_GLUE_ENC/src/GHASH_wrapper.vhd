--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : GHASH_wrapper
-- Module Name   : GHASH_wrapper - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : Stream wrapper around the pipelined GHASH core.
--                 Absorbs every incoming AXIS beat (AAD followed by
--                 CT, TLAST on the last CT) into the core, then pushes
--                 the 128-bit lengths block (AAD_bit_len || CT_bit_len)
--                 as the final GHASH input to produce the GCM
--                 authentication digest Y.
--                 FSM:
--                   S_ABSORB    - feed slave beats into the core; on
--                                 TLAST go to S_SEND_LEN if the length
--                                 is already latched, else S_WAIT_LEN
--                   S_WAIT_LEN  - wait for i_len_valid
--                   S_SEND_LEN  - drive the lengths block into the
--                                 core with i_last=1
--                   S_WAIT_Y    - wait for the core's Y_valid, return
--                                 to S_ABSORB
--                 With MULT_CYCLES=2 the core's two-stage multiplier is
--                 throttled by r_pipe_busy: w_core_valid is asserted at
--                 most every other cycle and s_axis_tready drops on busy
--                 cycles, so upstream beats are held by the skid buffer.
--                 With MULT_CYCLES=1 the throttle never asserts and the
--                 wrapper absorbs one block per cycle.
--                 H is latched once via i_H_valid and reused across
--                 packets. o_Y / o_Y_valid mirror the core's outputs
--                 directly.
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std, work.GHASH
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 Active-low reset.
--                 When i_len_valid arrives the SAME cycle as TLAST,
--                 the FSM jumps S_ABSORB -> S_SEND_LEN directly and
--                 w_lengths_block selects the LIVE side-band inputs
--                 (since the latch registers update next cycle).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity GHASH_wrapper is
    generic (
        MULT_CYCLES : integer := 2   -- GHASH multiply timing: 1 or 2 clock cycles
    );
    port (
        i_clk          : in  std_logic;
        i_rstn         : in  std_logic;

        -- AXIS slave: AAD blocks ‖ CT blocks (TLAST on last CT beat)
        s_axis_tdata   : in  std_logic_vector(127 downto 0);
        s_axis_tvalid  : in  std_logic;
        s_axis_tlast   : in  std_logic;
        s_axis_tready  : out std_logic;

        -- Hash subkey from AES-CTR
        i_H            : in  std_logic_vector(127 downto 0);
        i_H_valid      : in  std_logic;

        -- Side-band lengths (latched on i_len_valid pulse)
        i_aad_bit_len  : in  std_logic_vector(63 downto 0);
        i_ct_bit_len   : in  std_logic_vector(63 downto 0);
        i_len_valid    : in  std_logic;

        -- Result
        o_Y            : out std_logic_vector(127 downto 0);
        o_Y_valid      : out std_logic
    );
end entity;

architecture rtl of GHASH_wrapper is

    -- Latched values
    signal r_H           : std_logic_vector(127 downto 0) := (others => '0');
    signal r_aad_bit_len : std_logic_vector(63 downto 0)  := (others => '0');
    signal r_ct_bit_len  : std_logic_vector(63 downto 0)  := (others => '0');

    -- Tracks whether the length side-band for the CURRENT packet has been
    -- latched. The lengths block must NOT be pushed into the core until this
    -- is set, otherwise S_SEND_LEN may read a stale length from the previous
    -- packet.
    signal r_len_seen    : std_logic := '0';

    -- FSM states:
    --   S_ABSORB    : absorb AAD/CT beats into the core
    --   S_WAIT_LEN  : wait for the length side-band (fallback path)
    --   S_SEND_LEN  : drive the 128-bit lengths block into the core
    --   S_WAIT_Y    : wait for the core's Y output, return to S_ABSORB
    type state_t is (S_ABSORB, S_WAIT_LEN, S_SEND_LEN, S_WAIT_Y);
    signal state_reg  : state_t := S_ABSORB;
    signal next_state : state_t := S_ABSORB;

    -- GHASH core signals (combinational wires driving u_ghash inputs +
    -- registered output Y from the core).
    signal w_core_init  : std_logic;
    signal w_core_valid : std_logic;
    signal w_core_last  : std_logic;
    signal w_core_X     : std_logic_vector(127 downto 0);
    signal w_core_Y     : std_logic_vector(127 downto 0);
    signal w_core_Yvld  : std_logic;

    signal w_lengths_block : std_logic_vector(127 downto 0);

    -- Combinational: is the length available THIS cycle (latched or arriving)?
    signal w_len_ready : std_logic;

    -- Pipeline throttle: '1' for the cycle following any w_core_valid='1'.
    -- During that cycle the multiplier's second stage drives r_Y; the FSM
    -- must not feed a new operand into the multiplier or accept a new beat.
    signal r_pipe_busy : std_logic := '0';

begin

    ----------------------------------------------------------------
    -- Latch H on i_H_valid pulse
    ----------------------------------------------------------------
    p_H_LATCH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_H_valid = '1' then
                r_H <= i_H;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- Latch lengths on i_len_valid pulse, and remember that the
    -- current packet's length has been captured (r_len_seen).
    -- r_len_seen is cleared once the lengths block is pushed into
    -- the core (S_SEND_LEN). The clear is written BEFORE the set so
    -- that a coincident i_len_valid wins and we never lose a pulse.
    ----------------------------------------------------------------
    p_LEN_LATCH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_aad_bit_len <= (others => '0');
                r_ct_bit_len  <= (others => '0');
                r_len_seen    <= '0';
            else
                if state_reg = S_SEND_LEN then
                    r_len_seen <= '0';
                end if;

                if i_len_valid = '1' then
                    r_aad_bit_len <= i_aad_bit_len;
                    r_ct_bit_len  <= i_ct_bit_len;
                    r_len_seen    <= '1';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- Lengths block: AAD len (64-bit BE) ‖ CT len (64-bit BE)
    -- When the length is arriving THIS cycle (i_len_valid) the latched
    -- registers are not yet updated, so select the live inputs; otherwise
    -- use the latched values. This keeps S_SEND_LEN correct even when we
    -- jumped to it on a same-cycle length arrival.
    ----------------------------------------------------------------
    w_lengths_block <= (i_aad_bit_len & i_ct_bit_len) when i_len_valid = '1'
                     else (r_aad_bit_len & r_ct_bit_len);

    -- Length is usable this cycle if already latched or arriving now
    w_len_ready <= r_len_seen or i_len_valid;

    ----------------------------------------------------------------
    -- FSM state register (sequential)
    ----------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                state_reg <= S_ABSORB;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- FSM next-state logic (combinational). Transitions out of S_ABSORB
    -- and S_SEND_LEN require r_pipe_busy='0' so the cycle the lengths
    -- block / TLAST beat actually enters the multiplier completes
    -- before advancing.
    ----------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, s_axis_tvalid, s_axis_tlast,
                           w_len_ready, w_core_Yvld, r_pipe_busy)
    begin
        next_state <= state_reg;
        case state_reg is
            when S_ABSORB =>
                -- TLAST beat is accepted on a non-busy cycle. On accept,
                -- jump to S_SEND_LEN if the length side-band is already
                -- latched; otherwise wait for it.
                if r_pipe_busy = '0' and
                   s_axis_tvalid = '1' and s_axis_tlast = '1' then
                    if w_len_ready = '1' then
                        next_state <= S_SEND_LEN;
                    else
                        next_state <= S_WAIT_LEN;
                    end if;
                end if;

            when S_WAIT_LEN =>
                if w_len_ready = '1' then
                    next_state <= S_SEND_LEN;
                end if;

            when S_SEND_LEN =>
                -- Stay until the lengths block has actually been driven
                -- into the multiplier (the non-busy cycle that asserts
                -- w_core_valid='1').
                if r_pipe_busy = '0' then
                    next_state <= S_WAIT_Y;
                end if;

            when S_WAIT_Y =>
                if w_core_Yvld = '1' then
                    next_state <= S_ABSORB;
                end if;
        end case;
    end process;

    ----------------------------------------------------------------
    -- Combinational outputs
    ----------------------------------------------------------------

    -- Ready to absorb only on a non-busy ABSORB cycle (pipeline available)
    s_axis_tready <= '1' when (state_reg = S_ABSORB and r_pipe_busy = '0') else '0';

    -- Reset accumulator one cycle after Y is valid (transitioning back to ABSORB)
    w_core_init <= '1' when (state_reg = S_WAIT_Y and w_core_Yvld = '1') else '0';

    -- Core valid: when absorbing AXIS beat OR when sending lengths block,
    -- but never on a busy cycle (the multiplier's stage 2 needs that cycle).
    w_core_valid <= '1' when (state_reg = S_ABSORB and s_axis_tvalid = '1' and r_pipe_busy = '0') else
                  '1' when (state_reg = S_SEND_LEN and r_pipe_busy = '0') else
                  '0';

    w_core_last <= '1' when (state_reg = S_SEND_LEN and r_pipe_busy = '0') else '0';

    ----------------------------------------------------------------
    -- Pipeline throttle register. r_pipe_busy is set the cycle after
    -- w_core_valid='1' and cleared on the following cycle, producing
    -- the canonical 1-on / 1-off duty cycle the pipelined multiplier
    -- requires.
    ----------------------------------------------------------------
    p_PIPE_BUSY : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_pipe_busy <= '0';
            elsif MULT_CYCLES = 2 and w_core_valid = '1' then
                r_pipe_busy <= '1';
            else
                r_pipe_busy <= '0';
            end if;
        end if;
    end process;

    w_core_X <= w_lengths_block when state_reg = S_SEND_LEN else
              s_axis_tdata;

    ----------------------------------------------------------------
    -- GHASH core instance
    ----------------------------------------------------------------
    u_ghash : entity work.GHASH
        generic map (
            MULT_CYCLES => MULT_CYCLES
        )
        port map (
            i_clk     => i_clk,
            i_rstn    => i_rstn,
            i_init    => w_core_init,
            i_valid   => w_core_valid,
            i_last    => w_core_last,
            i_X       => w_core_X,
            i_H       => r_H,
            o_Y       => w_core_Y,
            o_Y_valid => w_core_Yvld
        );

    o_Y       <= w_core_Y;
    o_Y_valid <= w_core_Yvld;

end architecture;
