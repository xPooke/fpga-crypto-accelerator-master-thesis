----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : ecdh_deserializer
-- Module Name   : ecdh_deserializer - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : AXI-Stream slave -> parallel operands. Receives the packet
--                 cmd || Qx || Qy (each field ceil(G_M/DATA_WIDTH) words, LSB
--                 word first; cmd is a single word), packs it into parallel
--                 outputs and pulses o_valid at the end of the packet (TLAST).
--                 The scalar k does NOT travel through the stream (side-band
--                 in the wrapper) — the packet does not contain it.
--                 A generic AXIS "gearbox"; part of the ecdh_axis_ip wrapper.
--
-- Dependencies  : (none)
--
-- Revision      :
--   0.01 - August 2026 - File Created
--
-- Additional Comments :
--   Synchronous, active-low reset (i_resetn). Accepts a new packet only while
--   i_ready='1' (the wrapper drops it while the core is computing). LSB-word-
--   first packing: word 0 = bits DATA_WIDTH-1..0, etc; the upper partial word
--   is zero-padded. Input TKEEP is IGNORED (full words assumed). Malformed
--   packets: too short (early TLAST) -> silently dropped and reset; too long
--   -> S_DROP swallows until TLAST. The word carrying TLAST is still packed —
--   TLAST only ends the packet (it is data + framing, not framing alone).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

entity ecdh_deserializer is
    generic (
        G_M        : integer := 4;
        DATA_WIDTH : integer := 8
    );
    port (
        i_clk   : in  std_logic;
        i_resetn : in  std_logic;
        -- AXI-Stream slave
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tlast  : in  std_logic;
        -- parallel operands (stable from o_valid onward)
        i_ready : in  std_logic;                             -- wrapper ready for a new packet
        o_cmd   : out std_logic_vector(DATA_WIDTH-1 downto 0);
        o_qx    : out std_logic_vector(G_M-1 downto 0);
        o_qy    : out std_logic_vector(G_M-1 downto 0);
        o_valid : out std_logic                              -- 1-clock pulse: packet complete
    );
end entity;


architecture rtl of ecdh_deserializer is

    constant c_N : integer := (G_M + DATA_WIDTH - 1) / DATA_WIDTH;
                   -- words per field (Qx, Qy): ceil(4/8) = 1

    type state_t is (S_COLLECT, S_PRESENT, S_WAIT, S_DROP);
    signal state_reg, next_state : state_t := S_COLLECT;

    ----------------------------------------------------------------------------
    -- Datapath registers
    ----------------------------------------------------------------------------
    -- beat 0 = cmd, 1..N = Qx, N+1..2N = Qy
    signal r_beat           : integer range 0 to 2*c_N := 0;
    signal r_cmd            : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal r_qx_sh, r_qy_sh : std_logic_vector(c_N*DATA_WIDTH-1 downto 0) := (others => '0');

    signal w_accept : std_logic;   -- a word is accepted this clock

begin

    ----------------------------------------------------------------------------
    -- Combinational, slave side
    ----------------------------------------------------------------------------
    -- words are accepted in S_COLLECT/S_DROP while the wrapper is ready
    s_axis_tready <= i_ready when (state_reg = S_COLLECT or state_reg = S_DROP) else '0';
    w_accept <= '1' when (s_axis_tvalid = '1' and i_ready = '1'
                          and (state_reg = S_COLLECT or state_reg = S_DROP)) else '0';

    ----------------------------------------------------------------------------
    -- Combinational, parallel (master) side
    ----------------------------------------------------------------------------
    o_cmd   <= r_cmd;
    o_qx    <= r_qx_sh(G_M-1 downto 0);
    o_qy    <= r_qy_sh(G_M-1 downto 0);
    o_valid <= '1' when state_reg = S_PRESENT else '0';

    ----------------------------------------------------------------------------
    -- FSM state register
    ----------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                state_reg <= S_COLLECT;
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
        next_state <= state_reg;

        case state_reg is

            when S_COLLECT =>
                if w_accept = '1' then
                    if s_axis_tlast = '1' then
                        if r_beat = 2*c_N then
                            next_state <= S_PRESENT;   -- exact length -> packet ready
                        else
                            next_state <= S_COLLECT;   -- too short -> drop (datapath resets)
                        end if;
                    elsif r_beat = 2*c_N then
                        next_state <= S_DROP;          -- too long (no TLAST where expected)
                    end if;
                end if;

            when S_PRESENT =>
                next_state <= S_WAIT;                  -- o_valid pulse, 1 clock

            when S_WAIT =>
                if i_ready = '1' then                  -- wrapper ready again
                    next_state <= S_COLLECT;
                end if;

            when S_DROP =>
                if w_accept = '1' and s_axis_tlast = '1' then
                    next_state <= S_COLLECT;
                end if;

        end case;
    end process;

    ----------------------------------------------------------------------------
    -- Datapath: beat counter + word packing (LSB-word-first shift)
    ----------------------------------------------------------------------------
    p_DATAPATH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_resetn = '0' then
                r_beat  <= 0;
                r_cmd   <= (others => '0');
                r_qx_sh <= (others => '0');
                r_qy_sh <= (others => '0');
            else
                case state_reg is

                    when S_COLLECT =>
                        if w_accept = '1' then
                            -- ALWAYS pack the word by beat (including the one
                            -- carrying TLAST!)
                            if r_beat = 0 then
                                r_cmd <= s_axis_tdata;       -- first word = command
                            elsif r_beat <= c_N then
                                r_qx_sh <= s_axis_tdata & r_qx_sh(c_N*DATA_WIDTH-1 downto DATA_WIDTH);
                            else
                                r_qy_sh <= s_axis_tdata & r_qy_sh(c_N*DATA_WIDTH-1 downto DATA_WIDTH);
                            end if;
                            -- advance / finish the packet
                            if s_axis_tlast = '1' then
                                r_beat <= 0;                 -- end of packet (complete or short)
                            elsif r_beat < 2*c_N then
                                r_beat <= r_beat + 1;
                            end if;
                        end if;

                    when S_PRESENT =>
                        r_beat <= 0;   -- ready for the next packet

                    when S_DROP =>
                        if w_accept = '1' and s_axis_tlast = '1' then
                            r_beat <= 0;
                        end if;

                    when others =>
                        null;

                end case;
            end if;
        end if;
    end process;

end architecture;
