----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : May 2026
-- Design Name   : aes_enc_pipelined
-- Module Name   : aes_enc_pipelined - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Fully-pipelined AES-128/256 encryptor, NR+2 stages
--                 (12 or 16). Round keys come in via i_keys; KeyExpansion
--                 lives in the wrapper. Main rounds (1..NR-1) use aes_round
--                 (BRAM or LUT per ROUND_STYLE); the last round is inline,
--                 LUT-only (no MixColumns). FLOW_STYLE picks GLOBAL (one
--                 shared CE) or PER_STAGE (per-stage occupancy counter).
--                 Throughput: 1 block / cycle when the pipeline is filled.
--
-- Dependencies  : work.aes_pkg, work.aes_round
--
-- Revision      :
--   0.01 - May 2026 - File Created
--
-- Additional Comments :
--   Active-low reset (i_rstn). i_flush is active high; clears valid bits and
--   PER_STAGE counters without disturbing data registers or i_keys. Last
--   round forces rom_style="distributed" on a local SBOX signal to stop
--   Vivado from packing the inline SBOX into BRAM (Synth 8-5733 ignores the
--   attribute on package constants).
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.aes_pkg.all;

entity aes_enc_pipelined is
    generic (
        AES_BITS    : integer := 128;       -- 128 or 256
        ROUND_STYLE : string  := "BRAM";    -- "BRAM" or "LUT"
        FLOW_STYLE  : string  := "GLOBAL";  -- "GLOBAL" or "PER_STAGE"
        TUSER_WIDTH : integer := 2          -- AXIS TUSER side-channel width
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;                                   -- active low
        i_flush       : in  std_logic;                                   -- active high; drain pipeline
        i_keys        : in  arr_round_keys_t;                             -- k0..k14
        -- AXIS slave (input). s_axis_tuser is an opaque side-channel tag
        -- (e.g. block class) carried alongside data through every stage;
        -- this module never inspects it.
        s_axis_tdata  : in  std_logic_vector(127 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tuser  : in  std_logic_vector(TUSER_WIDTH-1 downto 0) := (others => '0');
        -- AXIS master (output). m_axis_tuser = s_axis_tuser of the block
        -- being emitted on the same beat.
        m_axis_tdata  : out std_logic_vector(127 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tuser  : out std_logic_vector(TUSER_WIDTH-1 downto 0);

        -- Side-band: '1' while any pipeline stage holds a valid block
        -- (registered OR of the valid vector)
        o_encryption_in_proc : out std_logic
    );
end entity;

architecture rtl of aes_enc_pipelined is

    constant c_NR             : integer := AES_BITS / 32 + 6;   -- 10 or 14
    constant c_LAST_IDX       : integer := c_NR + 1;            -- last stage index
    constant c_PIPELINE_DEPTH : integer := c_NR + 2;            -- 12 or 16

    ----------------------------------------------------------------------------
    -- Local SBOX with rom_style="distributed" (Synth 8-5733 workaround;
    -- Vivado honors the attribute on a signal but not on a package constant)
    ----------------------------------------------------------------------------
    signal w_lcl_sbox : sbox_array_t := c_SBOX;
    attribute rom_style : string;
    attribute rom_style of w_lcl_sbox : signal is "distributed";

    ----------------------------------------------------------------------------
    -- Pipeline data path
    ----------------------------------------------------------------------------
    type arr_w_state_t is array (0 to c_LAST_IDX) of std_logic_vector(127 downto 0);
    signal arr_w_state        : arr_w_state_t;                                        -- output of each stage
    signal r_input_stage      : std_logic_vector(127 downto 0) := (others => '0');    -- stage 0 FF: data_in XOR K0
    signal r_pre_last_round   : std_logic_vector(127 downto 0) := (others => '0');    -- stage NR FF: timing buffer before last round
    signal r_last_round_stage : std_logic_vector(127 downto 0) := (others => '0');    -- stage NR+1 FF: final CT

    ----------------------------------------------------------------------------
    -- Valid + TUSER side-channel (one element per stage)
    ----------------------------------------------------------------------------
    type arr_tuser_t is array (0 to c_LAST_IDX) of std_logic_vector(TUSER_WIDTH-1 downto 0);
    signal r_valid_vector : std_logic_vector(0 to c_LAST_IDX) := (others => '0');  -- per-stage valid bit; cleared on i_flush
    signal r_encryption_in_proc : std_logic := '0';                                 -- registered OR of r_valid_vector
    signal r_tuser        : arr_tuser_t := (others => (others => '0'));            -- per-stage TUSER tag; NOT cleared on i_flush

    ----------------------------------------------------------------------------
    -- Per-stage control wires
    ----------------------------------------------------------------------------
    signal arr_w_upstream_valid : std_logic_vector(0 to c_LAST_IDX);  -- wire alias for uniform generate loops (stage 0 -> s_axis_tvalid, i>=1 -> r_valid_vector(i-1))
    signal arr_w_clk_en         : std_logic_vector(0 to c_LAST_IDX);  -- per-stage CE; driven by selected FLOW_STYLE generate

    ----------------------------------------------------------------------------
    -- AXIS handshake helpers
    ----------------------------------------------------------------------------
    signal w_s_axis_tready   : std_logic;   -- internal copy of s_axis_tready
    signal w_m_axis_tvalid   : std_logic;   -- internal copy of m_axis_tvalid
    signal w_input_transfer  : std_logic;   -- s_axis_tvalid AND w_s_axis_tready
    signal w_output_transfer : std_logic;   -- w_m_axis_tvalid AND m_axis_tready

begin

    --------------------------------------------------------------------------
    -- Generic validation
    --------------------------------------------------------------------------
    assert (AES_BITS = 128) or (AES_BITS = 256)
        report "aes_enc_pipelined: AES_BITS must be 128 or 256"
        severity failure;
    assert (ROUND_STYLE = "BRAM") or (ROUND_STYLE = "LUT")
        report "aes_enc_pipelined: ROUND_STYLE must be ""BRAM"" or ""LUT"""
        severity failure;
    assert (FLOW_STYLE = "GLOBAL") or (FLOW_STYLE = "PER_STAGE")
        report "aes_enc_pipelined: FLOW_STYLE must be ""GLOBAL"" or ""PER_STAGE"""
        severity failure;

    --------------------------------------------------------------------------
    -- AXIS port hookup + transfer flags
    --------------------------------------------------------------------------
    s_axis_tready    <= w_s_axis_tready;
    m_axis_tvalid    <= w_m_axis_tvalid;
    m_axis_tdata     <= r_last_round_stage;
    m_axis_tuser     <= r_tuser(c_LAST_IDX);

    w_m_axis_tvalid   <= r_valid_vector(c_LAST_IDX);
    w_input_transfer  <= s_axis_tvalid    and w_s_axis_tready;
    w_output_transfer <= w_m_axis_tvalid  and m_axis_tready;

    --------------------------------------------------------------------------
    -- Upstream-valid map: stage 0 gets s_axis_tvalid; stage i gets prev valid
    --------------------------------------------------------------------------
    arr_w_upstream_valid(0) <= s_axis_tvalid;
    gen_upstream_map : for i in 1 to c_LAST_IDX generate
        arr_w_upstream_valid(i) <= r_valid_vector(i-1);
    end generate;

    --------------------------------------------------------------------------
    -- Valid-vector propagation: each stage's CE controls its update
    --------------------------------------------------------------------------
    p_VALID : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' or i_flush = '1' then
                -- Reset OR flush clears all valid bits -> pipeline appears empty
                r_valid_vector <= (others => '0');
            else
                for i in 0 to c_LAST_IDX loop
                    if arr_w_clk_en(i) = '1' then
                        r_valid_vector(i) <= arr_w_upstream_valid(i);
                    end if;
                end loop;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- "Diode" indicator: registered OR of every stage's valid bit.
    --------------------------------------------------------------------------
    p_DIODE : process(i_clk)
        variable v_or : std_logic;
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_encryption_in_proc <= '0';
            else
                v_or := '0';
                for i in 0 to c_LAST_IDX loop
                    v_or := v_or or r_valid_vector(i);
                end loop;
                r_encryption_in_proc <= v_or;
            end if;
        end if;
    end process p_DIODE;

    o_encryption_in_proc <= r_encryption_in_proc;

    --------------------------------------------------------------------------
    -- TUSER propagation: same CE pattern as valid. Stage 0 latches s_axis_tuser,
    -- subsequent stages shift from previous. NOT cleared on i_flush.
    --------------------------------------------------------------------------
    p_TUSER : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_tuser <= (others => (others => '0'));
            else
                if arr_w_clk_en(0) = '1' then
                    r_tuser(0) <= s_axis_tuser;
                end if;
                for i in 1 to c_LAST_IDX loop
                    if arr_w_clk_en(i) = '1' then
                        r_tuser(i) <= r_tuser(i-1);
                    end if;
                end loop;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- STAGE 0: input register, holds (data_in XOR k0)  -- initial AddRoundKey
    --------------------------------------------------------------------------
    p_STAGE0 : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_input_stage <= (others => '0');
            elsif arr_w_clk_en(0) = '1' then
                r_input_stage <= s_axis_tdata xor i_keys(0);
            end if;
        end if;
    end process;
    arr_w_state(0) <= r_input_stage;

    --------------------------------------------------------------------------
    -- STAGES 1..c_NR-1: main rounds via aes_round (each is 1 pipeline stage)
    --------------------------------------------------------------------------
    gen_main_rounds : for i in 1 to c_NR-1 generate
        u_round : entity work.aes_round
            generic map (
                ROUND_STYLE => ROUND_STYLE
            )
            port map (
                i_clk       => i_clk,
                i_clk_en    => arr_w_clk_en(i),
                i_state     => arr_w_state(i-1),
                i_round_key => i_keys(i),
                o_state     => arr_w_state(i),
                o_sub_bytes => open
            );
    end generate;

    --------------------------------------------------------------------------
    -- STAGE NR: extra register to decouple round c_NR-1 BRAM output from the
    -- combinational logic of the last round (SB + SR + AK). Without this
    -- register the path "BRAM(round c_NR-1) -> XOR -> SBOX -> AK" had four LUT
    -- levels after BRAM clk-to-Q and missed timing on K26 -2LV.
    --------------------------------------------------------------------------
    p_PRE_LAST_ROUND : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_pre_last_round <= (others => '0');
            elsif arr_w_clk_en(c_NR) = '1' then
                r_pre_last_round <= arr_w_state(c_NR-1);
            end if;
        end if;
    end process;
    arr_w_state(c_NR) <= r_pre_last_round;

    --------------------------------------------------------------------------
    -- STAGE NR+1 (c_LAST_IDX): last round (SB + SR + AK with k_NR), inline, no MC
    -- SubBytes is unrolled here using w_lcl_sbox (forced to distributed LUTs).
    --------------------------------------------------------------------------
    p_LAST_ROUND : process(i_clk)
        variable v_subbed : std_logic_vector(127 downto 0);
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_last_round_stage <= (others => '0');
            elsif arr_w_clk_en(c_LAST_IDX) = '1' then
                -- Inline SubBytes via local SBOX signal (rom_style=distributed)
                for i in 0 to 15 loop
                    v_subbed(127 - i*8 downto 120 - i*8) :=
                        w_lcl_sbox(to_integer(unsigned(
                            r_pre_last_round(127 - i*8 downto 120 - i*8))));
                end loop;
                r_last_round_stage <= add_round_key(shift_rows(v_subbed),
                                                    i_keys(c_NR));
            end if;
        end if;
    end process;
    arr_w_state(c_LAST_IDX) <= r_last_round_stage;

    --------------------------------------------------------------------------
    -- FLOW CONTROL (selected by FLOW_STYLE)
    --------------------------------------------------------------------------

    ----------------------------------------------------------------------
    -- GLOBAL: one enable for the entire pipeline, driven directly by the
    -- last-stage valid bit and the downstream ready. No separate occupancy
    -- counter -- valid_vector itself is the source of truth, which avoids
    -- the desync that an incremental counter suffers when the pipeline
    -- shifts bubbles internally (clock fires but no AXIS transfer matches).
    --
    -- Rules:
    --   * Accept new input when the last stage is empty OR is draining
    --     this cycle (then a slot frees up immediately).
    --   * Clock when there is a real transfer happening: either a new
    --     input lands, or an output drains. Never clock when m_tready=0
    --     AND r_valid_vector(c_LAST_IDX)='1' -- that would shift the held
    --     ciphertext away and lose it.
    ----------------------------------------------------------------------
    gen_flow_global : if FLOW_STYLE = "GLOBAL" generate
        signal w_clk_en : std_logic;
    begin
        w_s_axis_tready <= '1' when r_valid_vector(c_LAST_IDX) = '0'
                                 or m_axis_tready = '1'
                            else '0';

        w_clk_en <= '1' when (m_axis_tready = '1')
                         or (s_axis_tvalid = '1' and r_valid_vector(c_LAST_IDX) = '0')
                    else '0';

        arr_w_clk_en <= (others => w_clk_en);
    end generate gen_flow_global;

    ----------------------------------------------------------------------
    -- PER_STAGE: one counter per stage, threshold decreases with stage idx
    -- (carried over from my earlier AES_pipeline_impl design)
    ----------------------------------------------------------------------
    gen_flow_per_stage : if FLOW_STYLE = "PER_STAGE" generate
        type arr_r_counter_t is array (0 to c_LAST_IDX) of integer range 0 to c_PIPELINE_DEPTH + 4;
        signal r_counters : arr_r_counter_t := (others => 0);
    begin
        -- Per-stage enable: drain OR (room in stages-from-here AND new input)
        gen_enables : for i in 0 to c_LAST_IDX generate
            arr_w_clk_en(i) <= '1' when (m_axis_tready = '1')
                                    or (r_counters(i) < c_PIPELINE_DEPTH - i
                                        and s_axis_tvalid = '1')
                                else '0';
        end generate;

        -- s_axis_tready based on counter(0) (global pipeline occupancy)
        w_s_axis_tready <= '1' when r_counters(0) < c_PIPELINE_DEPTH
                           else m_axis_tready;

        -- Counter updates: increment when item enters but none leaves, decrement
        -- when item leaves but none enters, hold otherwise. Gated by stage CE.
        p_COUNTERS : process(i_clk)
        begin
            if rising_edge(i_clk) then
                if i_rstn = '0' or i_flush = '1' then
                    r_counters <= (others => 0);
                else
                    for i in 0 to c_LAST_IDX loop
                        if arr_w_clk_en(i) = '1' then
                            if w_output_transfer = '1'
                               and arr_w_upstream_valid(i) = '0' then
                                r_counters(i) <= r_counters(i) - 1;
                            elsif w_output_transfer = '0'
                               and arr_w_upstream_valid(i) = '1' then
                                r_counters(i) <= r_counters(i) + 1;
                            end if;
                        end if;
                    end loop;
                end if;
            end if;
        end process;
    end generate gen_flow_per_stage;

end architecture;