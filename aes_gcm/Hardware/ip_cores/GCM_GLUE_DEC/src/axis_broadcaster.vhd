--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : axis_broadcaster
-- Module Name   : axis_broadcaster - Behavioral
-- Tool Version  : Vivado 2025.1
-- Description   : 1-slave to N-master AXIS broadcaster, no buffering.
--                 VHDL-only equivalent of xilinx.com:ip:axis_broadcaster:1.1
--                 with the configuration used in tcl_bd/GCM.tcl and
--                 tcl_bd/GCM_wrapper_dec.tcl:
--                   HAS_TKEEP  = configurable
--                   HAS_TLAST  = configurable
--                   HAS_TREADY = always (TREADY-based broadcaster)
--                   S/M TDATA_NUM_BYTES = DATA_WIDTH / 8
--                   No TUSER, TDEST, TID, TSTRB
--                 Handshake: the slave fires when ALL master TREADY
--                 signals are '1' (AND-reduce). The same TDATA / TKEEP /
--                 TLAST are broadcast to every master in parallel. If one
--                 master is slow, the slave back-pressures.
-- Dependencies  : ieee.std_logic_1164
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 Purely combinational — i_clk / i_rstn are kept on the
--                 port list for interface parity with the Xilinx IP and
--                 the rest of gcm_glue, but are NOT used internally.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity axis_broadcaster is
    generic (
        NUM_MASTERS : positive := 2;
        DATA_WIDTH  : positive := 128;
        HAS_TKEEP   : boolean  := true;
        HAS_TLAST   : boolean  := true
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;

        -- AXIS slave (input)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tlast  : in  std_logic;
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXIS master (N outputs, side-by-side bit arrays)
        m_axis_tdata  : out std_logic_vector(NUM_MASTERS*DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(NUM_MASTERS*(DATA_WIDTH/8)-1 downto 0);
        m_axis_tlast  : out std_logic_vector(NUM_MASTERS-1 downto 0);
        m_axis_tvalid : out std_logic_vector(NUM_MASTERS-1 downto 0);
        m_axis_tready : in  std_logic_vector(NUM_MASTERS-1 downto 0)
    );
end entity;

architecture Behavioral of axis_broadcaster is

    signal w_all_ready : std_logic;

begin

    --------------------------------------------------------------------------
    -- AND-reduce of master tready
    --------------------------------------------------------------------------
    p_AND : process(m_axis_tready)
        variable v_and : std_logic;
    begin
        v_and := '1';
        for i in 0 to NUM_MASTERS-1 loop
            v_and := v_and and m_axis_tready(i);
        end loop;
        w_all_ready <= v_and;
    end process;

    --------------------------------------------------------------------------
    -- Slave handshake: ready only when every master is ready.
    --------------------------------------------------------------------------
    s_axis_tready <= w_all_ready;

    --------------------------------------------------------------------------
    -- Master broadcasts: same TDATA / TKEEP / TLAST replicated; TVALID
    -- gated by w_all_ready so the fire on every master happens in lock-step
    -- with the slave fire.
    --------------------------------------------------------------------------
    gen_masters : for i in 0 to NUM_MASTERS-1 generate
        m_axis_tdata((i+1)*DATA_WIDTH-1 downto i*DATA_WIDTH) <= s_axis_tdata;

        gen_tkeep : if HAS_TKEEP generate
            m_axis_tkeep((i+1)*(DATA_WIDTH/8)-1 downto i*(DATA_WIDTH/8)) <= s_axis_tkeep;
        end generate;
        gen_no_tkeep : if not HAS_TKEEP generate
            m_axis_tkeep((i+1)*(DATA_WIDTH/8)-1 downto i*(DATA_WIDTH/8)) <= (others => '1');
        end generate;

        gen_tlast : if HAS_TLAST generate
            m_axis_tlast(i) <= s_axis_tlast;
        end generate;
        gen_no_tlast : if not HAS_TLAST generate
            m_axis_tlast(i) <= '0';
        end generate;

        m_axis_tvalid(i) <= s_axis_tvalid and w_all_ready;
    end generate;

end architecture;
