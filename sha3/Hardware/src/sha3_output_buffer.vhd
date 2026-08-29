----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : January 2026
-- Design Name   : sha3_output_buffer
-- Module Name   : sha3_output_buffer - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Serializes the squeezed output into DATA_WIDTH words on the
--                 AXI-Stream master side, lowest byte first. Buffers one
--                 CHUNK_BITS chunk from the sponge; while it drains, the
--                 sponge already permutes the next chunk, so the stages overlap.
--                 TLAST marks the last of the OUT_BITS/DATA_WIDTH words.
--
-- Dependencies  : (none)
--
-- Revision      :
--   0.01 - January 2026 - File Created
--
-- Additional Comments :
--   Active-low synchronous reset. CHUNK_BITS = OUT_BITS for SHA3 (single
--   chunk) or the sponge rate for SHAKE; both divisible by DATA_WIDTH
--   (checked in sha3_top). Backpressure-safe: every word, including the
--   last, stays valid until m_axis_tready accepts it. A follow-up chunk
--   arriving in time is spliced in with zero idle beats (bypass load of
--   its first word in the same cycle the chunk is captured).
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sha3_output_buffer is
    generic (
        DATA_WIDTH : integer := 32;    -- AXIS data width
        OUT_BITS   : integer := 256;   -- total output size in bits
        CHUNK_BITS : integer := 256    -- chunk size handed over by the sponge
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;                                   -- active low

        -- Chunk handover from the sponge
        i_chunk       : in  std_logic_vector(CHUNK_BITS - 1 downto 0);
        i_chunk_valid : in  std_logic;
        o_chunk_ready : out std_logic;

        -- AXI-Stream master (output)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity;

architecture rtl of sha3_output_buffer is

    constant c_CHUNK_WORDS : integer := CHUNK_BITS / DATA_WIDTH;  -- words per chunk
    constant c_TOTAL_WORDS : integer := OUT_BITS / DATA_WIDTH;    -- words per message

    ----------------------------------------------------------------------------
    -- FSM
    ----------------------------------------------------------------------------
    type state_t is (S_IDLE, S_LOAD, S_SEND);
    signal state_reg, next_state : state_t;

    ----------------------------------------------------------------------------
    -- Chunk buffer + serialization counters
    ----------------------------------------------------------------------------
    signal r_chunk      : std_logic_vector(CHUNK_BITS - 1 downto 0);  -- buffered chunk
    signal r_chunk_word : integer range 0 to c_CHUNK_WORDS := 0;      -- words loaded from r_chunk
    signal r_total_word : integer range 0 to c_TOTAL_WORDS := 0;      -- words loaded this message
    signal r_tvalid     : std_logic := '0';                          -- un-consumed word in m_axis_tdata

begin

    ----------------------------------------------------------------------------
    -- Chunk capture + word serialization. A word is loaded whenever the data
    -- register is free (r_tvalid = '0') or being drained (m_axis_tready = '1').
    ----------------------------------------------------------------------------
    p_DATA_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_chunk_word <= 0;
                r_total_word <= 0;
                r_tvalid     <= '0';
                r_chunk      <= (others => '0');
                m_axis_tdata <= (others => '0');
            else
                case state_reg is

                    when S_IDLE =>
                        r_chunk_word <= 0;
                        r_total_word <= 0;
                        r_tvalid     <= '0';
                        if i_chunk_valid = '1' then
                            r_chunk <= i_chunk;
                        end if;

                    when S_LOAD =>
                        m_axis_tdata <= r_chunk(DATA_WIDTH - 1 downto 0);
                        r_chunk_word <= 1;
                        r_total_word <= 1;
                        r_tvalid     <= '1';

                    when S_SEND =>
                        if r_tvalid = '0' or m_axis_tready = '1' then
                            if r_total_word < c_TOTAL_WORDS then
                                if r_chunk_word < c_CHUNK_WORDS then
                                    -- Next word from the buffered chunk
                                    m_axis_tdata <= r_chunk((r_chunk_word + 1) * DATA_WIDTH - 1 downto
                                                            r_chunk_word * DATA_WIDTH);
                                    r_chunk_word <= r_chunk_word + 1;
                                    r_total_word <= r_total_word + 1;
                                    r_tvalid     <= '1';
                                elsif i_chunk_valid = '1' then
                                    -- Chunk drained and the sponge already has
                                    -- the next one: capture it and bypass-load
                                    -- its first word -- zero idle beats
                                    m_axis_tdata <= i_chunk(DATA_WIDTH - 1 downto 0);
                                    r_chunk      <= i_chunk;
                                    r_chunk_word <= 1;
                                    r_total_word <= r_total_word + 1;
                                    r_tvalid     <= '1';
                                else
                                    -- Waiting for the sponge to finish permuting
                                    r_tvalid <= '0';
                                end if;
                            else
                                -- Final word consumed (FSM leaves to S_IDLE)
                                r_tvalid <= '0';
                            end if;
                        end if;

                end case;
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
                state_reg <= S_IDLE;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- FSM next-state logic
    ----------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, i_chunk_valid, r_total_word, r_tvalid,
                           m_axis_tready)
    begin
        next_state <= state_reg;  -- default: stay

        case state_reg is

            when S_IDLE =>
                if i_chunk_valid = '1' then
                    next_state <= S_LOAD;
                end if;

            when S_LOAD =>
                next_state <= S_SEND;

            when S_SEND =>
                -- Leave after the LAST word's handshake completes
                if r_total_word = c_TOTAL_WORDS and r_tvalid = '1'
                   and m_axis_tready = '1' then
                    next_state <= S_IDLE;
                end if;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Outputs. The chunk buffer is free once all its words are loaded
    -- (r_chunk_word = c_CHUNK_WORDS), so the next chunk is accepted while
    -- the tail of the previous one is still on the AXIS bus.
    ----------------------------------------------------------------------------
    m_axis_tvalid <= r_tvalid;

    m_axis_tlast  <= '1' when r_total_word = c_TOTAL_WORDS else '0';

    p_CHUNK_READY : process(state_reg, r_chunk_word, r_total_word, r_tvalid,
                            m_axis_tready)
    begin
        o_chunk_ready <= '0';

        case state_reg is
            when S_IDLE =>
                o_chunk_ready <= '1';
            when S_SEND =>
                if r_chunk_word = c_CHUNK_WORDS and r_total_word < c_TOTAL_WORDS
                   and (r_tvalid = '0' or m_axis_tready = '1') then
                    o_chunk_ready <= '1';
                end if;
            when others =>
                null;
        end case;
    end process;

end architecture;
