----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : MERGE_mux
-- Module Name   : MERGE_mux - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   :
--   Re-assembles one contiguous AXI-Stream packet from two slaves:
--     * s_bypass : the bypass segment, passed through untouched (ends on TLAST).
--     * s_crypto : the AES-GCM core output  AAD || CT || ICV  (runtime length,
--                  terminated by TLAST; internal sub-segments may end on a
--                  partial beat marked by TKEEP).
--   The two are concatenated byte-contiguous on m_axis; only the final output
--   beat is partial.  A byte packer (gearbox + carry count) normalises any
--   sequence of TKEEP-tagged beats into full output beats, so AAD / CT / ICV
--   need NO dedicated states - a single S_MERGE handles them all.
--
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std, work.util_merge
--
-- Revision      :
--   0.01 - July 2026 - File Created
--   0.02 - August 2026 - Bypass = 0 is now supported: added the BYPASS_EN
--          generic. When false the bypass slave is disabled - the FSM starts in
--          S_MERGE and forwards the crypto stream straight through.
--
-- Additional Comments :
--   Active-low reset (i_rstn).
--   AXIS byte order: lane 0 = TDATA[7:0] = first/oldest byte; the gearbox is
--   right-aligned (oldest carried byte at the LSB).
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_merge.all;


entity MERGE_mux is
    generic (
        DATA_WIDTH : positive := 128;
        BYPASS_EN  : boolean  := true   -- true = bypass slave present (as before);
                                        -- false = disabled, s_bypass ignored (no stream)
    );
    port (
        i_clk  : in  std_logic;
        i_rstn : in  std_logic;

        -- AXIS slave: bypass (bypass segment, untouched)
        s_bypass_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_bypass_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_bypass_axis_tvalid : in  std_logic;
        s_bypass_axis_tlast  : in  std_logic;
        s_bypass_axis_tready : out std_logic;

        -- AXIS slave: crypto (AAD || CT || ICV) from the AES-GCM core
        s_crypto_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_crypto_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_crypto_axis_tvalid : in  std_logic;
        s_crypto_axis_tlast  : in  std_logic;
        s_crypto_axis_tready : out std_logic;

        -- AXIS master (downstream, one contiguous packet)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity;

architecture rtl of MERGE_mux is

    ----------------------------------------------------------------------------
    -- Constants
    ----------------------------------------------------------------------------
    constant c_BUS_BYTES    : positive := DATA_WIDTH / 8;      -- bytes per beat
    constant c_GB_CNT_WIDTH : positive := clog2(c_BUS_BYTES);  -- holds 0 .. bus-1
    constant c_WORK_WIDTH   : positive := 2 * DATA_WIDTH;      -- merge working vector

    ----------------------------------------------------------------------------
    -- FSM
    --   S_BYPASS : pack the bypass header (switch to S_MERGE on bypass TLAST)
    --   S_MERGE  : pack AAD || CT || ICV (flush / finish on crypto TLAST)
    --   S_FLUSH  : emit the leftover carry as the final partial beat
    ----------------------------------------------------------------------------
    type state_t is (S_BYPASS, S_MERGE, S_FLUSH);

    -- Start (and inter-packet idle) state. With the bypass slave disabled the FSM
    -- skips S_BYPASS and merges the crypto stream straight through.
    function init_state (en : boolean) return state_t is
    begin
        if en then return S_BYPASS; else return S_MERGE; end if;
    end function;

    constant c_INIT_STATE : state_t := init_state(BYPASS_EN);

    signal state_reg, next_state : state_t := c_INIT_STATE;

    ----------------------------------------------------------------------------
    -- Gearbox carry (right-aligned at the LSB) + valid-byte count
    ----------------------------------------------------------------------------
    signal r_gearbox  : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal r_gb_count : unsigned(c_GB_CNT_WIDTH-1 downto 0)     := (others => '0');

    signal w_next_gearbox : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_next_count   : unsigned(c_GB_CNT_WIDTH-1 downto 0);
    signal w_load         : std_logic;  -- commit the carry this cycle (= active handshake)

    ----------------------------------------------------------------------------
    -- Packer combinational (shared datapath wires, computed once)
    ----------------------------------------------------------------------------
    signal w_in_data : std_logic_vector(DATA_WIDTH-1 downto 0);   -- muxed active input
    signal w_in_keep : std_logic_vector(c_BUS_BYTES-1 downto 0);
    signal w_in_last : std_logic;                                 -- active-input TLAST (datapath)
    signal w_merged  : unsigned(c_WORK_WIDTH-1 downto 0);         -- carry ++ shifted input
    signal w_total   : natural;                                   -- carry bytes + input bytes
    signal w_emit    : std_logic;                                 -- drive an output beat this cycle

begin

    --------------------------------------------------------------------------
    -- (1) Active input mux + (2) packer maths.  w_in_last is the datapath
    --     TLAST (only crypto ends the packet).  w_merged is the single barrel
    --     shifter: carry (low, clean) OR input (masked) shifted up by the count.
    --------------------------------------------------------------------------
    w_in_data <= s_bypass_axis_tdata when state_reg = S_BYPASS else s_crypto_axis_tdata;
    w_in_keep <= s_bypass_axis_tkeep when state_reg = S_BYPASS else s_crypto_axis_tkeep;
    w_in_last <= s_crypto_axis_tlast when state_reg = S_MERGE  else '0';

    w_merged  <= resize(unsigned(r_gearbox), c_WORK_WIDTH)
                 or shift_left(resize(unsigned(mask_bytes(w_in_data, w_in_keep)), c_WORK_WIDTH),
                               to_integer(r_gb_count) * 8);
    w_total   <= to_integer(r_gb_count) + keep_bytes(w_in_keep);
    -- emit a beat when carry+input fills a full beat, or on the forced final beat
    w_emit    <= '1' when (w_total >= c_BUS_BYTES) or (w_in_last = '1') else '0';

    --------------------------------------------------------------------------
    -- (3) Slave side: drive both TREADYs and the carry-commit enable.
    --     Emit beats couple to the downstream ready; absorb beats accept
    --     unconditionally (no output); S_FLUSH consumes no input.
    --------------------------------------------------------------------------
    p_SLAVE_READY : process(state_reg, w_emit, m_axis_tready,
                            s_bypass_axis_tvalid, s_crypto_axis_tvalid)
        variable v_rdy : std_logic;
    begin
        s_bypass_axis_tready <= '0';
        s_crypto_axis_tready <= '0';
        w_load               <= '0';

        case state_reg is

            when S_BYPASS =>
                if w_emit = '1' then
                    v_rdy := m_axis_tready;
                else
                    v_rdy := '1';
                end if;
                s_bypass_axis_tready <= v_rdy;
                w_load               <= s_bypass_axis_tvalid and v_rdy;

            when S_MERGE =>
                if w_emit = '1' then
                    v_rdy := m_axis_tready;
                else
                    v_rdy := '1';
                end if;
                s_crypto_axis_tready <= v_rdy;
                w_load               <= s_crypto_axis_tvalid and v_rdy;

            when S_FLUSH =>
                w_load <= m_axis_tready;   -- flush handshake (no input consumed)

        end case;
    end process;

    --------------------------------------------------------------------------
    -- (4) Master side: assemble the output beat.  Full beats except the final
    --     one (partial/exact) in S_MERGE and the S_FLUSH tail.
    --------------------------------------------------------------------------
    p_MASTER_OUT : process(state_reg, w_merged, w_total, w_in_last, r_gearbox, r_gb_count,
                           w_emit, s_bypass_axis_tvalid, s_crypto_axis_tvalid)
    begin
        m_axis_tdata  <= std_logic_vector(w_merged(DATA_WIDTH-1 downto 0));
        m_axis_tkeep  <= (others => '1');
        m_axis_tvalid <= '0';
        m_axis_tlast  <= '0';

        case state_reg is
            when S_BYPASS =>
                m_axis_tvalid <= s_bypass_axis_tvalid and w_emit;   -- header: never packet end

            when S_MERGE =>
                if w_in_last = '1' and w_total <= c_BUS_BYTES then
                    m_axis_tkeep <= keep_mask(w_total, c_BUS_BYTES); -- final partial/exact beat
                    m_axis_tlast <= '1';
                end if;
                m_axis_tvalid <= s_crypto_axis_tvalid and w_emit;

            when S_FLUSH =>
                m_axis_tdata  <= r_gearbox;
                m_axis_tkeep  <= keep_mask(to_integer(r_gb_count), c_BUS_BYTES);
                m_axis_tvalid <= '1';
                m_axis_tlast  <= '1';
        end case;
    end process;

    --------------------------------------------------------------------------
    -- (5) Next carry value (the only part with real branching): emit -> keep
    --     the overflow (high bytes); absorb -> keep everything (low bytes);
    --     crypto TLAST -> either stash the tail (flush) or clear.
    --     v_total is recomputed locally so the branch and the arithmetic
    --     always use one consistent snapshot.
    --------------------------------------------------------------------------
    p_NEXT_CARRY : process(state_reg, w_merged, w_in_keep, w_in_last, r_gearbox, r_gb_count)
        variable v_total : natural;
    begin
        v_total := to_integer(r_gb_count) + keep_bytes(w_in_keep);
        w_next_gearbox <= r_gearbox;   -- default: hold
        w_next_count   <= r_gb_count;

        case state_reg is

            when S_BYPASS =>
                if v_total >= c_BUS_BYTES then
                    w_next_gearbox <= std_logic_vector(w_merged(c_WORK_WIDTH-1 downto DATA_WIDTH));
                    w_next_count   <= to_unsigned(v_total - c_BUS_BYTES, c_GB_CNT_WIDTH);
                else
                    w_next_gearbox <= std_logic_vector(w_merged(DATA_WIDTH-1 downto 0));
                    w_next_count   <= to_unsigned(v_total, c_GB_CNT_WIDTH);
                end if;

            when S_MERGE =>
                if w_in_last = '1' and v_total > c_BUS_BYTES then
                    w_next_gearbox <= std_logic_vector(w_merged(c_WORK_WIDTH-1 downto DATA_WIDTH));
                    w_next_count   <= to_unsigned(v_total - c_BUS_BYTES, c_GB_CNT_WIDTH);
                elsif w_in_last = '1' then
                    w_next_gearbox <= (others => '0');
                    w_next_count   <= (others => '0');
                elsif v_total >= c_BUS_BYTES then
                    w_next_gearbox <= std_logic_vector(w_merged(c_WORK_WIDTH-1 downto DATA_WIDTH));
                    w_next_count   <= to_unsigned(v_total - c_BUS_BYTES, c_GB_CNT_WIDTH);
                else
                    w_next_gearbox <= std_logic_vector(w_merged(DATA_WIDTH-1 downto 0));
                    w_next_count   <= to_unsigned(v_total, c_GB_CNT_WIDTH);
                end if;

            when S_FLUSH =>
                w_next_gearbox <= (others => '0');
                w_next_count   <= (others => '0');

        end case;
    end process;

    --------------------------------------------------------------------------
    -- Gearbox / carry register
    --------------------------------------------------------------------------
    p_GEARBOX : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_gearbox  <= (others => '0');
                r_gb_count <= (others => '0');
            elsif w_load = '1' then
                r_gearbox  <= w_next_gearbox;
                r_gb_count <= w_next_count;
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
    -- FSM next-state logic.  w_load is the active-slave handshake; the crypto
    -- TLAST needs a flush iff the tail overflows the last beat (w_total > bus).
    --------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, w_load, s_bypass_axis_tlast, s_crypto_axis_tlast, w_total)
    begin
        next_state <= state_reg;
        case state_reg is

            when S_BYPASS =>
                if w_load = '1' and s_bypass_axis_tlast = '1' then
                    next_state <= S_MERGE;
                end if;

            when S_MERGE =>
                if w_load = '1' and s_crypto_axis_tlast = '1' then
                    if w_total > c_BUS_BYTES then
                        next_state <= S_FLUSH;
                    else
                        next_state <= c_INIT_STATE;
                    end if;
                end if;

            when S_FLUSH =>
                if w_load = '1' then
                    next_state <= c_INIT_STATE;
                end if;

        end case;
    end process;

end architecture;
