--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : axis_ghash_mux
-- Module Name   : axis_ghash_mux - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : 2-to-1 AXIS multiplexer that feeds GHASH_wrapper.
--                 Selects either the AAD slave or the CT slave as the
--                 outbound m_axis stream and switches on:
--                   S_AAD -> S_CT  after AAD_BEATS handshakes
--                   S_CT  -> S_AAD on the TLAST of the CT stream
--                 When AAD_BEATS = 0 the FSM is skipped entirely and the
--                 CT slave passes straight through (AAD slave idle).
--
--                 Zero-padding: bytes whose tkeep bit is '0' are forced
--                 to 0x00 BEFORE the data reaches GHASH. GCM requires
--                 the partial final AAD or CT block to be padded with
--                 zero bits so GHASH always absorbs a clean 128-bit
--                 polynomial coefficient. Because this mux feeds ONLY
--                 GHASH_wrapper, the masking does NOT touch the real CT
--                 data path — that comes off a separate broadcaster
--                 branch and stays intact for the receiver.
-- Dependencies  : ieee.std_logic_1164, ieee.numeric_std
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 Active-low reset.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity axis_ghash_mux is
    generic (
        AAD_BEATS  : natural  := 2;
        DATA_WIDTH : positive := 128
    );
    port (
        i_clk          : in  std_logic;
        i_rstn         : in  std_logic;

        -- AXIS slave 1: AAD input
        s_aad_tdata    : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_aad_tkeep    : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_aad_tvalid   : in  std_logic;
        s_aad_tready   : out std_logic;

        -- AXIS slave 2: CT input (TLAST signals end of packet)
        s_ct_tdata     : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_ct_tkeep     : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_ct_tvalid    : in  std_logic;
        s_ct_tlast     : in  std_logic;
        s_ct_tready    : out std_logic;

        -- AXIS master: combined output to GHASH wrapper
        m_axis_tdata   : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep   : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid  : out std_logic;
        m_axis_tlast   : out std_logic;
        m_axis_tready  : in  std_logic
    );
end entity;

architecture rtl of axis_ghash_mux is

    ----------------------------------------------------------------
    -- Zero-pad helper: any byte whose tkeep bit is '0' is forced to
    -- 0x00. This is the GCM zero-padding of the final partial block.
    -- Because this module feeds ONLY the GHASH wrapper, masking here
    -- does NOT affect the real CT output path (that is a separate
    -- branch off the broadcaster / AES-CTR). A full beat (all-ones
    -- tkeep) passes through unchanged.
    ----------------------------------------------------------------
    function zero_pad(data : std_logic_vector;
                      keep : std_logic_vector) return std_logic_vector is
        variable v_R : std_logic_vector(data'range) := data;
    begin
        for b in keep'range loop
            if keep(b) = '0' then
                v_R(8*b+7 downto 8*b) := (others => '0');
            end if;
        end loop;
        return v_R;
    end function;

begin

    ----------------------------------------------------------------
    -- Case 1: AAD present (AAD_BEATS > 0)
    -- Two-state FSM: routes either AAD slave or CT slave to master
    ----------------------------------------------------------------
    gen_with_aad : if AAD_BEATS > 0 generate

        type state_t is (S_AAD, S_CT);
        signal state_reg         : state_t := S_AAD;
        signal next_state        : state_t := S_AAD;
        signal r_aad_cnt         : unsigned(7 downto 0) := (others => '0');
        signal w_slave_handshake : std_logic;
        signal w_master_tvalid    : std_logic;

        signal w_data_sel : std_logic_vector(DATA_WIDTH-1 downto 0);
        signal w_keep_sel : std_logic_vector(DATA_WIDTH/8-1 downto 0);

    begin

        w_slave_handshake <= w_master_tvalid and m_axis_tready;

        p_STATE_REG : process(i_clk)
        begin
            if rising_edge(i_clk) then
                if i_rstn = '0' then
                    state_reg <= S_AAD;
                else
                    state_reg <= next_state;
                end if;
            end if;
        end process;

        p_NEXT_STATE : process(state_reg, w_slave_handshake, r_aad_cnt,
                               s_ct_tlast)
        begin
            next_state <= state_reg;
            case state_reg is
                when S_AAD =>
                    if w_slave_handshake = '1' and
                       r_aad_cnt = to_unsigned(AAD_BEATS - 1, r_aad_cnt'length) then
                        next_state <= S_CT;
                    end if;
                when S_CT =>
                    if w_slave_handshake = '1' and s_ct_tlast = '1' then
                        next_state <= S_AAD;
                    end if;
            end case;
        end process;

        p_AAD_CNT : process(i_clk)
        begin
            if rising_edge(i_clk) then
                if i_rstn = '0' then
                    r_aad_cnt <= (others => '0');
                elsif state_reg = S_AAD and w_slave_handshake = '1' then
                    if r_aad_cnt = to_unsigned(AAD_BEATS - 1, r_aad_cnt'length) then
                        r_aad_cnt <= (others => '0');
                    else
                        r_aad_cnt <= r_aad_cnt + 1;
                    end if;
                end if;
            end if;
        end process;

        -- Select active slave
        w_data_sel <= s_aad_tdata when state_reg = S_AAD else s_ct_tdata;
        w_keep_sel <= s_aad_tkeep when state_reg = S_AAD else s_ct_tkeep;

        -- Zero-pad invalid bytes before GHASH (no effect on full beats)
        m_axis_tdata <= zero_pad(w_data_sel, w_keep_sel);
        m_axis_tkeep <= w_keep_sel;

        w_master_tvalid <= s_aad_tvalid when state_reg = S_AAD else
                          s_ct_tvalid  when state_reg = S_CT  else
                          '0';
        m_axis_tvalid  <= w_master_tvalid;

        m_axis_tlast <= '0'        when state_reg = S_AAD else
                        s_ct_tlast when state_reg = S_CT  else
                        '0';

        s_aad_tready <= m_axis_tready when state_reg = S_AAD else '0';
        s_ct_tready  <= m_axis_tready when state_reg = S_CT  else '0';

    end generate;

    ----------------------------------------------------------------
    -- Case 2: No AAD (AAD_BEATS = 0)
    -- Direct passthrough from CT slave to master (with zero-pad)
    ----------------------------------------------------------------
    gen_no_aad : if AAD_BEATS = 0 generate

        s_aad_tready <= '0';

        m_axis_tdata  <= zero_pad(s_ct_tdata, s_ct_tkeep);
        m_axis_tkeep  <= s_ct_tkeep;
        m_axis_tvalid <= s_ct_tvalid;
        m_axis_tlast  <= s_ct_tlast;
        s_ct_tready   <= m_axis_tready;

    end generate;

end architecture;
