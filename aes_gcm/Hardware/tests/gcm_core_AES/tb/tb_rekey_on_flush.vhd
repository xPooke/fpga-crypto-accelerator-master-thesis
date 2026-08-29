----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_rekey_on_flush
-- Module Name   : tb_rekey_on_flush - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Minimal reproducer for the coincident rekey + flush deadlock. It
--                 shows the cause is the COINCIDENCE (a key + IV pulse on the flush_all
--                 cycle), not the packet size: the packet here is far above the 1-beat
--                 boundary and used to deadlock anyway. Packet B must open the
--                 pipeline.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rekey_on_flush is
    generic (
        G_WRAPPER_KIND : string  := "UNROLLED";  -- "UNROLLED" | "MULTICORE"
        G_NUM_CORES    : integer := 4;
        G_AES_BITS     : integer := 128;
        G_PKT_BEATS    : integer := 8;           -- 8 beats = 128 B
        G_REKEY_OFFSET : integer := 0            -- 0 = on flush (bug); >0 = after (ok)
    );
end entity;

architecture sim of tb_rekey_on_flush is
    constant c_PER : time := 5 ns;

    signal clk           : std_logic := '0';
    signal rstn          : std_logic := '0';

    signal i_key         : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '0');
    signal i_key_valid   : std_logic := '0';
    signal i_nonce       : std_logic_vector(95 downto 0) := (others => '0');
    signal i_nonce_valid : std_logic := '0';

    signal s_tdata       : std_logic_vector(127 downto 0) := (others => '0');
    signal s_tkeep       : std_logic_vector(15 downto 0)  := (others => '1');
    signal s_tvalid      : std_logic := '0';
    signal s_tlast       : std_logic := '0';
    signal s_tready      : std_logic;

    signal m_tdata       : std_logic_vector(127 downto 0);
    signal m_tkeep       : std_logic_vector(15 downto 0);
    signal m_tvalid      : std_logic;
    signal m_tlast       : std_logic;
    signal m_tready      : std_logic := '1';   -- downstream always ready (CT/ICV drains)

    signal done : boolean := false;
begin

    clk <= not clk after c_PER/2 when not done else '0';

    dut : entity work.gcm_enc
        generic map (
            AES_BITS => G_AES_BITS, ROUND_STYLE => "LUT",
            WRAPPER_KIND => G_WRAPPER_KIND, NUM_CORES => G_NUM_CORES,
            AAD_BEATS => 0, DATA_WIDTH => 128
        )
        port map (
            i_clk => clk, i_rstn => rstn,
            i_key => i_key, i_key_valid => i_key_valid,
            i_nonce => i_nonce, i_nonce_valid => i_nonce_valid,
            s_axis_tdata => s_tdata, s_axis_tkeep => s_tkeep,
            s_axis_tvalid => s_tvalid, s_axis_tlast => s_tlast, s_axis_tready => s_tready,
            m_axis_tdata => m_tdata, m_axis_tkeep => m_tkeep,
            m_axis_tvalid => m_tvalid, m_axis_tlast => m_tlast, m_axis_tready => m_tready
        );

    p_stim : process
        constant c_KEY0   : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '0');
        variable v_key1   : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '1');
        constant c_NONCE0 : std_logic_vector(95 downto 0) := x"000000000000000000000001";
        constant c_NONCE1 : std_logic_vector(95 downto 0) := x"000000000000000000000002";

        -- one beat: present until the handshake happens. If with_rekey, hold
        -- key1+nonce1 high during presentation -> sampled on the handshake edge.
        procedure send_beat(constant last : in std_logic; constant with_rekey : in boolean) is
        begin
            s_tdata  <= (others => '0');
            s_tkeep  <= (others => '1');
            s_tlast  <= last;
            s_tvalid <= '1';
            if with_rekey then
                i_key <= v_key1; i_key_valid <= '1';
                i_nonce <= c_NONCE1; i_nonce_valid <= '1';
            end if;
            loop
                wait until rising_edge(clk);
                exit when s_tready = '1';      -- handshake (tlast handshake = flush_all)
            end loop;
            s_tvalid <= '0';
            s_tlast  <= '0';
            i_key_valid <= '0';
            i_nonce_valid <= '0';
        end procedure;
    begin
        -- reset
        rstn <= '0';
        for i in 0 to 5 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        wait until rising_edge(clk);

        -- packet A key/nonce (idle apply)
        i_key <= c_KEY0; i_key_valid <= '1';
        i_nonce <= c_NONCE0; i_nonce_valid <= '1';
        wait until rising_edge(clk);
        i_key_valid <= '0'; i_nonce_valid <= '0';

        -- ===== PACKET A (G_PKT_BEATS beats) =====
        -- offset semantics (cycles relative to the flush_all handshake):
        --    < 0 : rekey |offset| cycles BEFORE the flush beat
        --    = 0 : rekey ON the flush handshake
        --    > 0 : rekey offset cycles AFTER the flush
        for b in 0 to G_PKT_BEATS-2 loop
            send_beat('0', false);
        end loop;

        if G_REKEY_OFFSET < 0 then
            -- pulse rekey, wait, only then send the flush beat
            i_key <= v_key1; i_key_valid <= '1';
            i_nonce <= c_NONCE1; i_nonce_valid <= '1';
            wait until rising_edge(clk);
            i_key_valid <= '0'; i_nonce_valid <= '0';
            for i in 1 to (-G_REKEY_OFFSET)-1 loop wait until rising_edge(clk); end loop;
            send_beat('1', false);
        else
            -- last beat = flush; rekey on flush when offset is 0
            send_beat('1', G_REKEY_OFFSET = 0);
            if G_REKEY_OFFSET > 0 then
                for i in 1 to G_REKEY_OFFSET loop wait until rising_edge(clk); end loop;
                i_key <= v_key1; i_key_valid <= '1';
                i_nonce <= c_NONCE1; i_nonce_valid <= '1';
                wait until rising_edge(clk);
                i_key_valid <= '0'; i_nonce_valid <= '0';
            end if;
        end if;

        report "packet A sent, rekey fired (offset=" & integer'image(G_REKEY_OFFSET)
             & "); waiting for packet B to open the pipeline...";

        -- ===== packet B: wait for s_axis_tready =====
        s_tdata  <= (others => '0');
        s_tkeep  <= (others => '1');
        s_tlast  <= '0';
        s_tvalid <= '1';
        for i in 1 to 5000 loop
            wait until rising_edge(clk);
            if s_tready = '1' then
                report "RESULT: PASS -- packet B opened the pipeline after "
                     & integer'image(i) & " cycles (no deadlock)";
                done <= true;
                wait;
            end if;
        end loop;

        assert false
            report "RESULT: FAIL -- DEADLOCK: a rekey coincident with flush_all "
                 & "(" & G_WRAPPER_KIND & ", packet " & integer'image(G_PKT_BEATS)
                 & " beats = " & integer'image(G_PKT_BEATS*16) & " B); "
                 & "s_axis_tready never rises"
            severity failure;
        wait;
    end process;

end architecture;
