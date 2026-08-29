----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : January 2026
-- Design Name   : sha3_input_buffer
-- Module Name   : sha3_input_buffer - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Accumulates AXI-Stream beats into rate-sized blocks for the
--                 Keccak sponge and applies sponge padding (PAD_BYTE ... 0x80)
--                 when TLAST arrives: 0x06 for SHA3, 0x1F for SHAKE.
--                 TKEEP-masked bytes of the final beat are cleared before the
--                 padding byte is placed. A message that ends exactly on a
--                 block boundary gets a separate padding-only block
--                 (S_PAD_BLOCK).
--
-- Dependencies  : (none)
--
-- Revision      :
--   0.01 - January 2026 - File Created
--   0.02 - August 2026  - Block held as a word array with a single indexed
--                         write port
--
-- Additional Comments :
--   Active-low synchronous reset. TKEEP is honoured only on the TLAST beat
--   (trailing mask); mid-message beats must carry full words. When the
--   padding byte lands on the last byte of the block, PAD_BYTE and 0x80
--   merge into one byte (0x86 for SHA3, 0x9F for SHAKE -- FIPS 202). A
--   TLAST beat that fills the block with a partial TKEEP keeps the FSM in
--   S_FILL one extra cycle so the in-block padding is applied before
--   handover. TREADY is low during that padding cycle, so dense
--   back-to-back packets are flow-controlled safely.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sha3_input_buffer is
    generic (
        RATE_WORDS : integer := 34;                                -- sponge rate in DATA_WIDTH words
        DATA_WIDTH : integer := 32;                                -- AXIS data width
        PAD_BYTE   : std_logic_vector(7 downto 0) := x"06"         -- 0x06 = SHA3, 0x1F = SHAKE
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;                                     -- active low
        i_config      : in  std_logic;                                     -- enable (leaves S_INIT)

        -- AXI-Stream slave (message in)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;                                     -- end of message
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH / 8 - 1 downto 0);

        -- Block handover to the sponge
        o_block       : out std_logic_vector(RATE_WORDS * DATA_WIDTH - 1 downto 0);
        o_block_valid : out std_logic;
        i_block_ready : in  std_logic;
        o_block_last  : out std_logic                                      -- block closes the message
    );
end entity;

architecture rtl of sha3_input_buffer is

    constant c_BYTE_WIDTH : integer := 8;
    constant c_NB         : integer := DATA_WIDTH / c_BYTE_WIDTH;  -- bytes per word

    ----------------------------------------------------------------------------
    -- The block is held as an array of words and every write goes through the
    -- single indexed port at the end of p_BLOCK_REG, so one address decoder
    -- serves both the data path and the padding path.
    ----------------------------------------------------------------------------
    type block_arr_t is array (0 to RATE_WORDS - 1)
        of std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal r_block : block_arr_t := (others => (others => '0'));

    -- Data of the TLAST beat. The padding cycle rebuilds that one word from
    -- this register, so padding never reads back the assembled block.
    signal r_last_word : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_INIT, S_FILL, S_SEND, S_PAD_BLOCK);
    signal state_reg, next_state : state_t;

    ----------------------------------------------------------------------------
    -- Block assembly
    ----------------------------------------------------------------------------
    signal r_word_counter : integer range 0 to RATE_WORDS := 0;       -- words stored in the current block
    signal r_masked_bytes : integer range 0 to DATA_WIDTH / 8 := 0;   -- TKEEP-masked bytes of the TLAST beat
    signal r_last_pending : std_logic := '0';                         -- TLAST beat stored, in-block padding still due
    signal r_padding_done : std_logic := '0';                         -- message closed: current block is the final one

    ----------------------------------------------------------------------------
    -- Count of contiguous '0' TKEEP bits from the MSB side (trailing mask)
    ----------------------------------------------------------------------------
    function count_masked_bytes(tkeep : std_logic_vector) return integer is
        variable v_cnt : integer := 0;
    begin
        for i in tkeep'range loop
            if tkeep(i) = '0' then
                v_cnt := v_cnt + 1;
            else
                exit;
            end if;
        end loop;
        return v_cnt;
    end function;

begin

    ----------------------------------------------------------------------------
    -- Block register: word storage, TLAST capture, in-block padding
    ----------------------------------------------------------------------------
    p_BLOCK_REG : process(i_clk)
        -- Description of the write to be issued this cycle; the assignment
        -- itself happens once, after the case statement.
        variable v_wr      : std_logic;
        variable v_idx     : integer range 0 to RATE_WORDS - 1;
        variable v_word    : std_logic_vector(DATA_WIDTH - 1 downto 0);
        variable v_set_msb : std_logic;
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_word_counter <= 0;
                r_masked_bytes <= 0;
                r_last_pending <= '0';
                r_padding_done <= '0';
                r_last_word    <= (others => '0');
                r_block        <= (others => (others => '0'));
            else
                v_wr      := '0';
                v_idx     := 0;
                v_word    := (others => '0');
                v_set_msb := '0';

                case state_reg is

                    when S_INIT =>
                        r_word_counter <= 0;
                        r_padding_done <= '0';
                        r_block        <= (others => (others => '0'));

                    when S_FILL =>
                        r_padding_done <= '0';

                        if r_last_pending = '0' then
                            -- Store the incoming word (s_axis_tready is high)
                            if s_axis_tvalid = '1' then
                                r_word_counter <= r_word_counter + 1;
                                r_last_word    <= s_axis_tdata;
                                v_wr   := '1';
                                v_idx  := r_word_counter;
                                v_word := s_axis_tdata;
                            end if;

                            -- Capture end-of-message info on the TLAST beat
                            if s_axis_tvalid = '1' and s_axis_tlast = '1' then
                                r_last_pending <= '1';
                                r_masked_bytes <= count_masked_bytes(s_axis_tkeep);
                            end if;
                        else
                            -- Padding cycle: s_axis_tready is LOW, so a beat of
                            -- the next message waits on the bus. Exactly one
                            -- word of the block changes, and it is written
                            -- through the same port as a data word.
                            v_wr := '1';
                            if r_masked_bytes = 0 then
                                -- Last beat filled its word completely: the pad
                                -- byte opens the next word.
                                v_idx  := r_word_counter;
                                v_word := (others => '0');
                                v_word(c_BYTE_WIDTH - 1 downto 0) := PAD_BYTE;
                            else
                                -- Keep the valid bytes of the last stored
                                -- word, put PAD_BYTE right after them and clear
                                -- the masked ones. The loop bound is static, so
                                -- this is a byte mux inside a single word.
                                v_idx := r_word_counter - 1;
                                for b in 0 to c_NB - 1 loop
                                    if b < c_NB - r_masked_bytes then
                                        v_word((b + 1) * c_BYTE_WIDTH - 1 downto b * c_BYTE_WIDTH)
                                            := r_last_word((b + 1) * c_BYTE_WIDTH - 1 downto b * c_BYTE_WIDTH);
                                    elsif b = c_NB - r_masked_bytes then
                                        v_word((b + 1) * c_BYTE_WIDTH - 1 downto b * c_BYTE_WIDTH)
                                            := PAD_BYTE;
                                    else
                                        v_word((b + 1) * c_BYTE_WIDTH - 1 downto b * c_BYTE_WIDTH)
                                            := (others => '0');
                                    end if;
                                end loop;
                            end if;

                            -- 0x80 = MSB of the block, applied after the word
                            -- write so a coincident PAD_BYTE in the top byte
                            -- merges correctly (0x86 / 0x9F)
                            v_set_msb := '1';

                            r_last_pending <= '0';
                            r_padding_done <= '1';
                        end if;  -- r_last_pending

                    when S_SEND =>
                        if i_block_ready = '1' then
                            r_word_counter <= 0;
                            r_block        <= (others => (others => '0'));
                        end if;

                    when S_PAD_BLOCK =>
                        -- Message ended exactly at a block boundary:
                        -- emit a padding-only block (PAD_BYTE ... 0x80)
                        r_padding_done <= '1';
                        v_wr      := '1';
                        v_idx     := 0;
                        v_word    := (others => '0');
                        v_word(c_BYTE_WIDTH - 1 downto 0) := PAD_BYTE;
                        v_set_msb := '1';
                        r_last_pending <= '0';

                end case;

                -- Single write port into the block.
                if v_wr = '1' then
                    r_block(v_idx) <= v_word;
                end if;
                if v_set_msb = '1' then
                    r_block(RATE_WORDS - 1)(DATA_WIDTH - 1) <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Flatten the word array onto the block port; static indices, wiring only.
    gen_block_out : for w in 0 to RATE_WORDS - 1 generate
        o_block((w + 1) * DATA_WIDTH - 1 downto w * DATA_WIDTH) <= r_block(w);
    end generate;

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
    p_NEXT_STATE : process(state_reg, i_config, r_last_pending, i_block_ready,
                           r_word_counter, s_axis_tvalid, s_axis_tlast,
                           s_axis_tkeep, r_padding_done)
    begin
        next_state <= state_reg;  -- default: stay

        case state_reg is

            when S_INIT =>
                if i_config = '1' then
                    next_state <= S_FILL;
                end if;

            when S_FILL =>
                -- A block-filling beat that is also TLAST with a partial
                -- TKEEP must NOT leave S_FILL yet: stay one extra cycle so
                -- the r_last_pending branch applies the in-block padding.
                if (r_word_counter = RATE_WORDS - 1 and s_axis_tvalid = '1'
                    and not (s_axis_tlast = '1'
                             and s_axis_tkeep(DATA_WIDTH / 8 - 1) = '0'))
                   or (r_last_pending = '1') then
                    next_state <= S_SEND;
                end if;

            when S_SEND =>
                if i_block_ready = '1' then
                    if r_padding_done = '1' then
                        next_state <= S_INIT;
                    elsif r_last_pending = '1' then
                        next_state <= S_PAD_BLOCK;
                    else
                        next_state <= S_FILL;
                    end if;
                end if;

            when S_PAD_BLOCK =>
                next_state <= S_SEND;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Outputs (TREADY drops during the padding cycle so a back-to-back beat
    -- of the next message waits on the bus instead of entering this block)
    ----------------------------------------------------------------------------
    p_OUTPUTS : process(state_reg, r_padding_done, r_last_pending)
    begin
        s_axis_tready <= '0';
        o_block_valid <= '0';
        o_block_last  <= '0';

        case state_reg is
            when S_FILL =>
                s_axis_tready <= not r_last_pending;
            when S_SEND =>
                o_block_valid <= '1';
                o_block_last  <= r_padding_done;
            when others =>
                null;
        end case;
    end process;

end architecture;
