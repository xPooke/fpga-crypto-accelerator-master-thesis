----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : January 2026
-- Design Name   : sha3_axis_ip
-- Module Name   : sha3_axis_ip - rtl
-- Project Name  : SHA3-224/256/384/512 + SHAKE128/256 accelerator (master thesis)
-- Tool Version  : Vivado 2025.1
--
-- Description   : AXI-Stream IP shell around sha3_top: message in on the
--                 slave interface, digest (SHA3) or SHAKE_BITS of XOF output
--                 (SHAKE) on the master interface. One TLAST-delimited
--                 packet = one message = one output packet.
--
-- Dependencies  : work.sha3_top
--
-- Revision      :
--   0.01 - January 2026 - File Created
--
-- Additional Comments :
--   Output TKEEP is all-ones (the output is always a whole number of
--   words -- enforced by the divisibility asserts in sha3_top).
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sha3_axis_ip is
    generic (
        ALGORITHM        : string  := "SHA3";   -- "SHA3", "SHAKE" or "CSHAKE"
        SHA3_VERSION     : string  := "256";    -- "224", "256", "384" or "512" (ALGORITHM = SHA3)
        SHAKE_VERSION    : string  := "256";    -- "128" or "256"               (ALGORITHM = SHAKE/CSHAKE)
        SHAKE_BITS       : integer := 1024;     -- output size in bits          (ALGORITHM = SHAKE/CSHAKE)
        DATA_WIDTH       : integer := 32;       -- AXIS data width (8, 16, 32, 64)
        ROUNDS_PER_CYCLE : integer := 1         -- Keccak rounds per clock (divisor of 24; 1-2 recommended)
    );
    port (
        axis_aclk    : in  std_logic;
        axis_aresetn : in  std_logic;                                      -- active low

        -- AXI-Stream slave (message in)
        s_axis_tvalid  : in  std_logic;
        s_axis_tready  : out std_logic;
        s_axis_tdata   : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        s_axis_tkeep   : in  std_logic_vector(DATA_WIDTH / 8 - 1 downto 0);
        s_axis_tlast   : in  std_logic;

        -- AXI-Stream master (digest out)
        m_axis_tvalid  : out std_logic;
        m_axis_tready  : in  std_logic;
        m_axis_tdata   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        m_axis_tkeep   : out std_logic_vector(DATA_WIDTH / 8 - 1 downto 0);
        m_axis_tlast   : out std_logic
    );
end entity;

architecture rtl of sha3_axis_ip is

begin

    u_sha3 : entity work.sha3_top
        generic map (
            ALGORITHM        => ALGORITHM,
            SHA3_VERSION     => SHA3_VERSION,
            SHAKE_VERSION    => SHAKE_VERSION,
            SHAKE_BITS       => SHAKE_BITS,
            DATA_WIDTH       => DATA_WIDTH,
            ROUNDS_PER_CYCLE => ROUNDS_PER_CYCLE
        )
        port map (
            i_clk         => axis_aclk,
            i_rstn        => axis_aresetn,
            i_config      => '1',             -- always enabled
            s_axis_tdata  => s_axis_tdata,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tkeep  => s_axis_tkeep,
            m_axis_tdata  => m_axis_tdata,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready,
            m_axis_tlast  => m_axis_tlast
        );

    -- Digest is always byte-aligned: all output bytes valid
    m_axis_tkeep <= (others => '1');

end architecture;
