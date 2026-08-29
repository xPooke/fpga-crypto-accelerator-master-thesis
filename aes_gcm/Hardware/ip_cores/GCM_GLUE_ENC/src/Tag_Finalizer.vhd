--------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
-- Project       : ETF Master Thesis
-- Create Date   : May 2026
-- Design Name   : Tag_Finalizer
-- Module Name   : Tag_Finalizer - rtl
-- Tool Version  : Vivado 2025.1
-- Description   : Computes the GCM authentication tag (ICV) on the
--                 encrypt side and emits it as a single AXIS beat.
--                 Latches E_K(J0) when its valid pulse arrives (computed
--                 early by AES-CTR), then on the GHASH 'Y' valid pulse
--                 computes:
--                   ICV = Y XOR E_K(J0)
--                 and presents it on m_axis as a one-beat transfer
--                 (TLAST = TVALID). The beat is held until the
--                 downstream consumer asserts m_axis_tready.
-- Dependencies  : ieee.std_logic_1164
-- Revision      : 0.01 - May 2026 - File created
-- Additional Comments :
--                 Active-low reset.
--                 r_EJ0 has no reset (latched only on i_EJ0_valid pulse)
--                 — E_K(J0) is always written before the first Y arrives.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity Tag_Finalizer is
    port (
        i_clk          : in  std_logic;
        i_rstn         : in  std_logic;

        -- E_K(J0) side-band (latched on valid)
        i_EJ0          : in  std_logic_vector(127 downto 0);
        i_EJ0_valid    : in  std_logic;

        -- Y side-band (from GHASH wrapper)
        i_Y            : in  std_logic_vector(127 downto 0);
        i_Y_valid      : in  std_logic;

        -- AXIS master: emits ICV
        m_axis_tdata   : out std_logic_vector(127 downto 0);
        m_axis_tvalid  : out std_logic;
        m_axis_tlast   : out std_logic;
        m_axis_tready  : in  std_logic
    );
end entity;

architecture rtl of Tag_Finalizer is
    signal r_EJ0  : std_logic_vector(127 downto 0) := (others => '0');
    signal r_ICV  : std_logic_vector(127 downto 0) := (others => '0');
    signal r_vld  : std_logic := '0';
begin

    ----------------------------------------------------------------
    -- Latch E_K(J0) when valid
    ----------------------------------------------------------------
    p_EJ0_LATCH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_EJ0_valid = '1' then
                r_EJ0 <= i_EJ0;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- Compute and latch ICV when Y arrives
    ----------------------------------------------------------------
    p_ICV : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_ICV <= (others => '0');
                r_vld <= '0';
            else
                if i_Y_valid = '1' then
                    r_ICV <= i_Y xor r_EJ0;
                    r_vld <= '1';
                elsif r_vld = '1' and m_axis_tready = '1' then
                    -- Beat consumed, deassert
                    r_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- AXIS master output
    ----------------------------------------------------------------
    m_axis_tdata  <= r_ICV;
    m_axis_tvalid <= r_vld;
    m_axis_tlast  <= r_vld;       -- single-beat transfer; TLAST = TVALID

end architecture;
