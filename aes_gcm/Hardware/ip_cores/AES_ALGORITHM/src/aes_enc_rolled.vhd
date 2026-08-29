----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : May 2026
-- Design Name   : aes_enc_rolled
-- Module Name   : aes_enc_rolled - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Iterative (rolled) AES-128/256 encryptor. A single
--                 aes_round instance is reused for NR-1 main rounds
--                 (BRAM T-tables or LUT per ROUND_STYLE); the last round
--                 is a separate combinational path (SB + SR + AK, no MC):
--                 in LUT mode it reuses the round's SubBytes tap, in BRAM
--                 mode a local distributed-LUT SBOX. Round keys
--                 K_1..K_NR live in a local 16x128 distributed-RAM copy
--                 written through the broadcast (i_rk_wr_*) stream the
--                 shared KeyExpansion drives while it expands; the write
--                 of K_j lands on the same clock edge as the KE's own
--                 K_j register, so the on-the-fly read timing holds
--                 ("K_i readable when the counter reaches i-1"). One
--                 async read port (address = round counter + 1) serves
--                 both the shared aes_round and the last round, so the
--                 core keeps no round-key mux at all. K_0 (initial
--                 AddRoundKey) comes in statically on i_key0. Latency:
--                 NR clocks to the result, but the result is then held
--                 in S_DONE until the wrapper consumes it, so a block
--                 occupies a core NR+1 clocks. Throughput: 1 block /
--                 (NR+1) cycles per instance, so NR+1 cores give one
--                 block per clock.
--                 Designed for instantiation in AES_multicore_wrapper.
--
-- Dependencies  : work.aes_pkg, work.aes_round
--
-- Revision      :
--   0.01 - May 2026 - File Created
--   0.02 - Aug 2026 - Round keys moved to a local 16x128 distributed-RAM
--                     copy written by the KeyExpansion broadcast stream;
--                     cycle-identical, no round-key mux in the core
--   0.03 - Aug 2026 - Last round reuses the round's SubBytes tap in LUT
--                     mode (final-cycle round input is the fed-back round
--                     output); local SBOX kept for BRAM mode only
--
-- Additional Comments :
--   Active-low reset (i_rstn). i_flush_all is active high; resets state,
--   counter and per-block registers without resetting the surrounding
--   wrapper. Last round uses LUTs even when ROUND_STYLE="BRAM" (forces
--   rom_style="distributed" on a local SBOX signal; Synth 8-5733
--   workaround). The round-key RAM has no reset: every location a core
--   can read is rewritten by the KE stream before the dispatch logic can
--   start that core (same just-in-time schedule as the register array).
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.aes_pkg.all;

entity aes_enc_rolled is
    generic (
        AES_BITS    : integer := 128;       -- 128 or 256
        ROUND_STYLE : string  := "BRAM"     -- "BRAM" or "LUT"
    );
    port (
        i_clk                : in  std_logic;
        i_rstn               : in  std_logic;                              -- active low

        -- Per-block crypto interface
        i_plaintext          : in  std_logic_vector(127 downto 0);
        i_start_enc          : in  std_logic;
        o_encryption_done    : out std_logic;
        o_encryption_ready   : out std_logic;
        o_encryption_in_proc : out std_logic;
        o_cipher_text        : out std_logic_vector(127 downto 0);

        -- Round keys. K_0 (initial AddRoundKey) is static from the KE's
        -- constant-index output (no mux). K_1..K_NR arrive through the
        -- broadcast write stream and land in the local distributed-RAM
        -- copy on the same clock edge as the KE's own registers, so the
        -- on-the-fly contract is unchanged: K_i is readable when
        -- r_counter reaches i-1, one cycle after KE produced it.
        i_key0               : in  std_logic_vector(127 downto 0);
        i_rk_wr_en           : in  std_logic;
        i_rk_wr_addr         : in  unsigned(3 downto 0);
        i_rk_wr_data         : in  std_logic_vector(127 downto 0);

        -- Wrapper-side block handshake
        i_block_consumed     : in  std_logic;  -- release strobe: the held S_DONE
                                               -- block is consumed THIS cycle (CT:
                                               -- PT present AND downstream ready;
                                               -- H/EK: unconditional)
        i_flush_all          : in  std_logic   -- packet-end clear: discard held /
                                               -- in-flight blocks (FSM, counter,
                                               -- block registers)
    );
end entity;

architecture rtl of aes_enc_rolled is

    constant c_NR    : integer := AES_BITS / 32 + 6;     -- 10 or 14
    constant c_CNT_W : integer := 4;                      -- enough for c_NR up to 15

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_ROUND_PROCESS, S_DONE);
    signal state_reg, next_state : state_t := S_IDLE;

    ----------------------------------------------------------------------------
    -- Round counter + per-block plaintext / ciphertext registers
    ----------------------------------------------------------------------------
    signal r_counter     : unsigned(c_CNT_W-1 downto 0)   := (others => '0');  -- round counter; counts 0..NR-1 in S_ROUND_PROCESS
    signal r_pt_captured : std_logic_vector(127 downto 0) := (others => '0');  -- input plaintext, latched on i_start_enc
    signal r_cipher_text : std_logic_vector(127 downto 0) := (others => '0');  -- final CT, latched when r_counter = NR-1

    ----------------------------------------------------------------------------
    -- Local round-key copy: 16 x 128 distributed RAM, synchronous write from
    -- the KE broadcast, asynchronous read by round counter. The one read
    -- port serves the shared aes_round (K_(counter+1)) and, on the
    -- last-round cycle (counter = NR-1), the last round's AddRoundKey
    -- (the same expression evaluates to K_NR there).
    ----------------------------------------------------------------------------
    type rk_ram_t is array (0 to 15) of std_logic_vector(127 downto 0);
    signal r_rk_ram : rk_ram_t := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of r_rk_ram : signal is "distributed";

    ----------------------------------------------------------------------------
    -- aes_round interface (single shared instance, reused for rounds 1..NR-1)
    ----------------------------------------------------------------------------
    signal w_round_in  : std_logic_vector(127 downto 0);  -- (r_pt_captured XOR K0) on first cycle, else feedback from w_round_out
    signal w_round_key : std_logic_vector(127 downto 0);  -- r_rk_ram(counter+1) — round key for the round being computed
    signal w_round_out : std_logic_vector(127 downto 0);  -- aes_round registered output
    signal w_round_ce  : std_logic;                       -- CE: '1' in S_ROUND_PROCESS while counter < NR-1

    ----------------------------------------------------------------------------
    -- Last round (combinational SB + SR + AK with K_NR)
    ----------------------------------------------------------------------------
    signal w_last_state : std_logic_vector(127 downto 0);  -- combinational last-round result before registering into r_cipher_text
    signal w_round_sub  : std_logic_vector(127 downto 0);  -- SubBytes tap out of aes_round (LUT mode)
    signal w_subbed     : std_logic_vector(127 downto 0);  -- last-round SubBytes input
    attribute rom_style : string;

begin

    --------------------------------------------------------------------------
    -- Generic validation
    --------------------------------------------------------------------------
    assert (AES_BITS = 128) or (AES_BITS = 256)
        report "aes_enc_rolled: AES_BITS must be 128 or 256"
        severity failure;
    assert (ROUND_STYLE = "BRAM") or (ROUND_STYLE = "LUT")
        report "aes_enc_rolled: ROUND_STYLE must be ""BRAM"" or ""LUT"""
        severity failure;

    --------------------------------------------------------------------------
    -- Local round-key RAM: write port (KE broadcast)
    --------------------------------------------------------------------------
    p_RK_RAM : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rk_wr_en = '1' then
                r_rk_ram(to_integer(i_rk_wr_addr)) <= i_rk_wr_data;
            end if;
        end if;
    end process;

    -- Async read: K_(counter+1) — the aes_round key for rounds 1..NR-1 and
    -- K_NR on the last-round cycle. Reads never race the writes: the core
    -- reads K_i one cycle after the edge that wrote it (dispatch-delay
    -- contract, unchanged from the register-array design).
    w_round_key <= r_rk_ram(to_integer(r_counter) + 1);

    --------------------------------------------------------------------------
    -- aes_round instance (reused for rounds 1..c_NR-1)
    --------------------------------------------------------------------------
    u_round : entity work.aes_round
        generic map (
            ROUND_STYLE => ROUND_STYLE
        )
        port map (
            i_clk       => i_clk,
            i_clk_en    => w_round_ce,
            i_state     => w_round_in,
            i_round_key => w_round_key,
            o_state     => w_round_out,
            o_sub_bytes => w_round_sub
        );

    -- Input mux to aes_round:
    --   counter = 0 -> initial AddRoundKey: r_pt_captured XOR K0
    --   else        -> feedback from aes_round's own registered output
    w_round_in <= (r_pt_captured xor i_key0) when r_counter = 0
                  else w_round_out;

    -- CE: only fire aes_round when actually producing a main round.
    -- Skip the last cycle (counter = c_NR-1) since the last round uses w_last_state.
    w_round_ce <= '1' when (state_reg = S_ROUND_PROCESS)
                       and (r_counter < to_unsigned(c_NR-1, c_CNT_W))
                  else '0';

    --------------------------------------------------------------------------
    -- Combinational last round: SubBytes + ShiftRows + AddRoundKey(K_NR).
    -- w_round_key equals K_NR exactly on the cycle this result is latched
    -- (counter = NR-1), the only cycle w_last_state is consumed.
    --------------------------------------------------------------------------
    -- LUT mode: in the final cycle the round input is the fed-back round
    -- output, so the round's SubBytes tap already computes SB(w_round_out)
    -- and no local SBOX is needed. BRAM mode keeps a local SBOX copy
    -- (T-tables fuse SubBytes with MixColumns, so there is no plain tap).
    gen_last_lut : if ROUND_STYLE = "LUT" generate
        w_subbed <= w_round_sub;
    end generate gen_last_lut;

    gen_last_bram : if ROUND_STYLE = "BRAM" generate
        signal w_lcl_sbox : sbox_array_t := c_SBOX;  -- rom_style: Synth 8-5733 workaround
        attribute rom_style of w_lcl_sbox : signal is "distributed";
    begin
        p_LAST_SBOX : process(w_round_out)
        begin
            for i in 0 to 15 loop
                w_subbed(127 - i*8 downto 120 - i*8) <=
                    w_lcl_sbox(to_integer(unsigned(
                        w_round_out(127 - i*8 downto 120 - i*8))));
            end loop;
        end process;
    end generate gen_last_bram;

    w_last_state <= add_round_key(shift_rows(w_subbed), w_round_key);

    --------------------------------------------------------------------------
    -- FSM state register
    --------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' or i_flush_all = '1' then
                state_reg <= S_IDLE;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM next-state logic (combinational)
    --------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, i_start_enc, r_counter,
                           i_block_consumed)
    begin
        next_state <= state_reg;
        case state_reg is
            when S_IDLE =>
                if i_start_enc = '1' then
                    next_state <= S_ROUND_PROCESS;
                end if;
            when S_ROUND_PROCESS =>
                if r_counter = to_unsigned(c_NR-1, c_CNT_W) then
                    next_state <= S_DONE;
                end if;
            when S_DONE =>
                if i_block_consumed = '1' then
                    if i_start_enc = '1' then
                        next_state <= S_ROUND_PROCESS;
                    else
                        next_state <= S_IDLE;
                    end if;
                end if;
        end case;
    end process;

    --------------------------------------------------------------------------
    -- Counter + PT capture
    --------------------------------------------------------------------------
    p_COUNTER : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' or i_flush_all = '1' then
                r_counter     <= (others => '0');
                r_pt_captured <= (others => '0');
            else
                case state_reg is
                    when S_IDLE =>
                        if i_start_enc = '1' then
                            r_pt_captured <= i_plaintext;
                            r_counter     <= (others => '0');
                        end if;
                    when S_ROUND_PROCESS =>
                        -- Stop at c_NR-1 so the round-key read r_rk_ram(counter+1)
                        -- never goes past K_NR. Counter resets to 0 on
                        -- next-packet start (in S_IDLE / S_DONE branches).
                        if r_counter < to_unsigned(c_NR-1, c_CNT_W) then
                            r_counter <= r_counter + 1;
                        end if;
                    when S_DONE =>
                        if i_block_consumed = '1' and i_start_enc = '1' then
                            r_pt_captured <= i_plaintext;
                            r_counter     <= (others => '0');
                        end if;
                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Output ciphertext register (latched at end of round_process)
    --------------------------------------------------------------------------
    p_CT_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' or i_flush_all = '1' then
                r_cipher_text <= (others => '0');
            elsif state_reg = S_ROUND_PROCESS
                  and r_counter = to_unsigned(c_NR-1, c_CNT_W) then
                r_cipher_text <= w_last_state;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Outputs
    --------------------------------------------------------------------------
    o_cipher_text        <= r_cipher_text;
    o_encryption_done    <= '1' when state_reg = S_DONE else '0';
    o_encryption_in_proc <= '1' when state_reg = S_ROUND_PROCESS else '0';

    -- Ready: '1' when in idle (can accept start), or when in done AND the
    -- output handshake fires this cycle (core will transition either to
    -- round_process or idle next cycle -- either way it can take new work).
    o_encryption_ready <= '1' when state_reg = S_IDLE else
                          '1' when (state_reg = S_DONE
                                    and i_block_consumed = '1') else
                          '0';

end architecture;
