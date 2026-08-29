----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : ICV_realign
-- Module Name   : ICV_realign - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   :
--   Decrypt-path adapter.  SPLIT_demux hands over  AAD || (CT || ICV)  where the
--   CT and the trailing 16-byte ICV are packed CONTIGUOUSLY, so the tag straddles
--   beats.  gcm_dec_glue (AXIS_DEMUX_dec) however requires the ICV to sit ALONE
--   on the final beat (TLAST beat = ICV beat).  This core re-aligns exactly that:
--
--     in : AAD beats | CT||ICV packed contiguously (TLAST on the last beat)
--     out: AAD beats | CT beats (last one partial) | ICV beat (full, TLAST)
--
--   It keeps one beat of look-behind (r_prev): only when TLAST arrives is it
--   known which bytes are the tag.  With k = valid bytes in the TLAST beat:
--     CT tail = r_prev[low k bytes]
--     ICV     = (r_prev >> k bytes) OR (r_last << (bus-k) bytes)
--
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std, work.util_merge
--
-- Revision      :
--   0.01 - July 2026 - File Created
--
-- Additional Comments :
--   Active-low reset (i_rstn).  The ICV is assumed to be exactly one full beat
--   (16 B on a 128-bit bus).
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_merge.all;

entity ICV_realign is
    generic (
        DATA_WIDTH : positive := 128;
        AAD_BEATS  : natural  := 2    -- beats passed through untouched up front
    );
    port (
        i_clk  : in  std_logic;
        i_rstn : in  std_logic;

        -- AXIS slave: AAD || (CT || ICV packed contiguously)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXIS master: AAD || CT (last beat partial) || ICV (own full beat, TLAST)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity;

architecture rtl of ICV_realign is

    constant c_BUS_BYTES : positive := DATA_WIDTH / 8;
    constant c_CNT_WIDTH : positive := clog2(AAD_BEATS + 1);

    ----------------------------------------------------------------------------
    -- FSM
    --   S_AAD    : pass the AAD beats straight through
    --   S_PRIME  : swallow the first CT||ICV beat into r_prev (no output)
    --   S_STREAM : emit r_prev as a full CT beat, load the next beat
    --   S_CTTAIL : emit the last (partial) CT beat from r_prev
    --   S_ICV    : emit the re-assembled ICV beat (TLAST)
    ----------------------------------------------------------------------------
    type state_t is (S_AAD, S_PRIME, S_STREAM, S_CTTAIL, S_ICV);

    function init_state(n : natural) return state_t is
    begin
        if n = 0 then
            return S_PRIME;
        else
            return S_AAD;
        end if;
    end function;

    constant c_INIT_STATE : state_t := init_state(AAD_BEATS);

    signal state_reg, next_state : state_t := c_INIT_STATE;

    signal r_cnt : unsigned(c_CNT_WIDTH-1 downto 0) := (others => '0');  -- AAD beats seen

    signal r_prev      : std_logic_vector(DATA_WIDTH-1 downto 0)   := (others => '0');
    signal r_last      : std_logic_vector(DATA_WIDTH-1 downto 0)   := (others => '0');
    signal r_last_keep : std_logic_vector(c_BUS_BYTES-1 downto 0)  := (others => '0');
    signal r_ct_empty  : std_logic := '0';   -- CT was empty (segment = ICV only)

    signal w_s_handshake : std_logic;         -- input beat accepted
    signal w_m_handshake : std_logic;         -- output beat accepted
    signal w_aad_last    : std_logic;         -- current beat is the last AAD beat

begin

    --------------------------------------------------------------------------
    -- Segment-last flag
    --------------------------------------------------------------------------
    p_SEG_FLAGS : process(state_reg, r_cnt)
    begin
        w_aad_last <= '0';

        if AAD_BEATS > 0 and state_reg = S_AAD and
           r_cnt = to_unsigned(AAD_BEATS-1, r_cnt'length) then
            w_aad_last <= '1';
        end if;
    end process;

    --------------------------------------------------------------------------
    -- Slave side: when do we accept an input beat?  S_PRIME and the TLAST beat
    -- of S_STREAM are swallowed (no output), so they accept unconditionally;
    -- S_CTTAIL and S_ICV emit from the look-behind registers alone and consume
    -- nothing.
    --------------------------------------------------------------------------
    p_SLAVE_IN : process(state_reg, s_axis_tvalid, s_axis_tlast, m_axis_tready)
        variable v_tready : std_logic;
    begin
        case state_reg is

            when S_AAD =>
                v_tready := m_axis_tready;         -- 1-in / 1-out passthrough

            when S_PRIME =>
                v_tready := '1';                   -- swallowed, no output

            when S_STREAM =>
                if s_axis_tlast = '0' then
                    v_tready := m_axis_tready;
                else
                    v_tready := '1';               -- absorb the TLAST beat
                end if;

            when others =>
                v_tready := '0';                   -- S_CTTAIL / S_ICV: drain only

        end case;

        s_axis_tready <= v_tready;
        w_s_handshake <= s_axis_tvalid and v_tready;
    end process;

    --------------------------------------------------------------------------
    -- Master side
    --------------------------------------------------------------------------
    p_MASTER_OUT : process(state_reg, s_axis_tdata, s_axis_tkeep, s_axis_tvalid,
                           s_axis_tlast, m_axis_tready, r_prev, r_last, r_last_keep,
                           r_ct_empty)
        variable v_k      : natural;
        variable v_icv    : unsigned(DATA_WIDTH-1 downto 0);
        variable v_tvalid : std_logic;
    begin
        m_axis_tdata <= r_prev;
        m_axis_tkeep <= (others => '1');
        m_axis_tlast <= '0';
        v_tvalid     := '0';

        v_k := keep_bytes(r_last_keep);

        case state_reg is

            when S_AAD =>                                  -- pass AAD through
                m_axis_tdata <= s_axis_tdata;
                m_axis_tkeep <= s_axis_tkeep;
                m_axis_tlast <= '0';
                v_tvalid     := s_axis_tvalid;

            when S_PRIME =>                                -- swallow, no output
                v_tvalid := '0';

            when S_STREAM =>                               -- emit the held beat as full CT
                m_axis_tdata <= r_prev;
                m_axis_tkeep <= (others => '1');
                m_axis_tlast <= '0';
                if s_axis_tlast = '0' then
                    v_tvalid := s_axis_tvalid;
                else
                    v_tvalid := '0';                       -- TLAST beat is absorbed
                end if;

            when S_CTTAIL =>                               -- last, partial CT beat
                m_axis_tdata <= r_prev;
                m_axis_tkeep <= keep_mask(v_k, c_BUS_BYTES);
                m_axis_tlast <= '0';
                v_tvalid     := '1';

            when S_ICV =>                                  -- the tag, alone, with TLAST
                if r_ct_empty = '1' then
                    v_icv := unsigned(r_prev);             -- segment was just the ICV
                else
                    v_icv := shift_right(unsigned(r_prev), v_k * 8)
                             or shift_left(unsigned(mask_bytes(r_last, r_last_keep)),
                                           (c_BUS_BYTES - v_k) * 8);
                end if;
                m_axis_tdata <= std_logic_vector(v_icv);
                m_axis_tkeep <= (others => '1');
                m_axis_tlast <= '1';
                v_tvalid     := '1';

        end case;

        m_axis_tvalid <= v_tvalid;
        w_m_handshake <= v_tvalid and m_axis_tready;
    end process;

    --------------------------------------------------------------------------
    -- Registers: AAD beat counter + the look-behind beats
    --------------------------------------------------------------------------
    p_REGS : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_cnt       <= (others => '0');
                r_prev      <= (others => '0');
                r_last      <= (others => '0');
                r_last_keep <= (others => '0');
                r_ct_empty  <= '0';
            else
                case state_reg is

                    when S_AAD =>
                        if w_m_handshake = '1' then
                            if w_aad_last = '1' then
                                r_cnt <= (others => '0');
                            else
                                r_cnt <= r_cnt + 1;
                            end if;
                        end if;

                    when S_PRIME =>
                        if w_s_handshake = '1' then
                            r_prev <= s_axis_tdata;
                            if s_axis_tlast = '1' then
                                -- degenerate: the whole segment is the ICV (CT = 0)
                                r_ct_empty  <= '1';
                                r_last_keep <= s_axis_tkeep;
                            else
                                r_ct_empty <= '0';
                            end if;
                        end if;

                    when S_STREAM =>
                        if w_s_handshake = '1' then
                            if s_axis_tlast = '1' then
                                r_last      <= s_axis_tdata;   -- tag straddles r_prev/r_last
                                r_last_keep <= s_axis_tkeep;
                            else
                                r_prev <= s_axis_tdata;        -- slide the window
                            end if;
                        end if;

                    when S_ICV =>
                        if w_m_handshake = '1' then
                            r_ct_empty <= '0';
                        end if;

                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM state register
    --------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                state_reg <= c_INIT_STATE;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- FSM next-state logic
    --------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, w_s_handshake, w_m_handshake, w_aad_last,
                           s_axis_tlast, r_ct_empty)
    begin
        next_state <= state_reg;
        case state_reg is

            when S_AAD =>
                if w_m_handshake = '1' and w_aad_last = '1' then
                    next_state <= S_PRIME;
                end if;

            when S_PRIME =>
                if w_s_handshake = '1' then
                    if s_axis_tlast = '1' then
                        next_state <= S_ICV;       -- CT empty, beat is the tag
                    else
                        next_state <= S_STREAM;
                    end if;
                end if;

            when S_STREAM =>
                if w_s_handshake = '1' and s_axis_tlast = '1' then
                    next_state <= S_CTTAIL;
                end if;

            when S_CTTAIL =>
                if w_m_handshake = '1' then
                    next_state <= S_ICV;
                end if;

            when S_ICV =>
                if w_m_handshake = '1' then
                    next_state <= c_INIT_STATE;    -- ready for the next packet
                end if;

        end case;
    end process;

end architecture;
