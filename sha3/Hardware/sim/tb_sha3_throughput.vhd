----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_sha3_throughput
-- Module Name   : tb_sha3_throughput - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Cycle-accurate throughput / latency characterization
--                 Long-message phase: G_MSG_BLOCKS rate blocks (minus one beat, so the last
--                 block carries in-block padding and the permutation count equals the block
--                 count) driven with TVALID held high; measures cycles from the first input
--                 handshake to the TLAST output beat and reports centibits-per-cycle.
--                 Throughput(Gbps) = (centibits_per_cycle / 100) * Fmax(GHz).
--                 Short-message phase: one 16-byte message; reports in -> TLAST latency in
--                 cycles (the per-derivation cost that matters for the KDF use case).
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sha3_throughput is
    generic (
        G_ALGORITHM        : string  := "SHA3";   -- "SHA3" or "SHAKE"
        G_SHA3_VERSION     : string  := "256";
        G_SHAKE_VERSION    : string  := "256";
        G_OUT_BITS         : integer := 1024;     -- SHAKE only
        G_DATA_WIDTH       : integer := 32;
        G_ROUNDS_PER_CYCLE : integer := 1;
        G_MSG_BLOCKS       : integer := 50
    );
end entity;

architecture sim of tb_sha3_throughput is

    constant c_CLK_PERIOD : time    := 10 ns;
    constant c_WB         : integer := G_DATA_WIDTH / 8;

    function digest_bits(ver : string) return integer is
    begin
        if    ver = "224" then return 224;
        elsif ver = "256" then return 256;
        elsif ver = "384" then return 384;
        else                   return 512;
        end if;
    end function;

    function rate_bits_f return integer is
    begin
        if G_ALGORITHM = "SHAKE" then
            if G_SHAKE_VERSION = "128" then return 1344; else return 1088; end if;
        else
            return 1600 - 2 * digest_bits(G_SHA3_VERSION);
        end if;
    end function;

    constant c_RATE_BITS  : integer := rate_bits_f;
    constant c_RATE_BYTES : integer := c_RATE_BITS / 8;
    -- one beat short of full blocks: padding stays in-block, permutations = blocks
    constant c_MSG_BYTES  : integer := G_MSG_BLOCKS * c_RATE_BYTES - c_WB;
    constant c_MSG_BEATS  : integer := c_MSG_BYTES / c_WB;
    constant c_MSG_BITS   : integer := c_MSG_BYTES * 8;

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';
    signal done : boolean   := false;

    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tdata  : std_logic_vector(G_DATA_WIDTH - 1 downto 0) := (others => '0');
    signal s_tkeep  : std_logic_vector(c_WB - 1 downto 0) := (others => '0');
    signal s_tlast  : std_logic := '0';

    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '1';
    signal m_tdata  : std_logic_vector(G_DATA_WIDTH - 1 downto 0);
    signal m_tkeep  : std_logic_vector(c_WB - 1 downto 0);
    signal m_tlast  : std_logic;

    signal r_cycle : integer := 0;

begin

    clk <= not clk after c_CLK_PERIOD / 2 when not done else '0';

    u_dut : entity work.sha3_axis_ip
        generic map (
            ALGORITHM        => G_ALGORITHM,
            SHA3_VERSION     => G_SHA3_VERSION,
            SHAKE_VERSION    => G_SHAKE_VERSION,
            SHAKE_BITS       => G_OUT_BITS,
            DATA_WIDTH       => G_DATA_WIDTH,
            ROUNDS_PER_CYCLE => G_ROUNDS_PER_CYCLE
        )
        port map (
            axis_aclk    => clk,
            axis_aresetn => rstn,
            s_axis_tvalid => s_tvalid,
            s_axis_tready => s_tready,
            s_axis_tdata  => s_tdata,
            s_axis_tkeep  => s_tkeep,
            s_axis_tlast  => s_tlast,
            m_axis_tvalid => m_tvalid,
            m_axis_tready => m_tready,
            m_axis_tdata  => m_tdata,
            m_axis_tkeep  => m_tkeep,
            m_axis_tlast  => m_tlast
        );

    p_CYCLE : process(clk)
    begin
        if rising_edge(clk) then
            r_cycle <= r_cycle + 1;
        end if;
    end process;

    p_MAIN : process
        variable v_guard : integer;
        variable v_t0    : integer;
        variable v_t_in  : integer;
        variable v_total : integer;
        variable v_cbpc  : integer;  -- centibits per cycle

        procedure send_beat(last : std_logic) is
        begin
            s_tvalid <= '1';
            s_tlast  <= last;
            s_tkeep  <= (others => '1');
            v_guard  := 0;
            loop
                wait until rising_edge(clk);
                exit when s_tready = '1';
                v_guard := v_guard + 1;
                assert v_guard < 5000 report "input TIMEOUT" severity failure;
            end loop;
        end procedure;

        procedure wait_tlast is
        begin
            v_guard := 0;
            loop
                wait until rising_edge(clk);
                exit when m_tvalid = '1' and m_tlast = '1';
                v_guard := v_guard + 1;
                assert v_guard < 100000 report "output TIMEOUT" severity failure;
            end loop;
        end procedure;
    begin
        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;

        ------------------------------------------------------------------------
        -- Phase 1: long message (steady-state throughput)
        ------------------------------------------------------------------------
        s_tdata <= (others => '1');
        send_beat('0');
        v_t0 := r_cycle;                       -- first beat accepted
        for b in 1 to c_MSG_BEATS - 1 loop
            if b = c_MSG_BEATS - 1 then send_beat('1'); else send_beat('0'); end if;
        end loop;
        s_tvalid <= '0';
        s_tlast  <= '0';
        v_t_in := r_cycle;                     -- last beat accepted

        wait_tlast;
        v_total := r_cycle - v_t0;
        v_cbpc  := (c_MSG_BITS / v_total) * 100
                 + ((c_MSG_BITS mod v_total) * 100) / v_total;

        report "THROUGHPUT " & G_ALGORITHM & "-"
             & G_SHA3_VERSION & "/" & G_SHAKE_VERSION
             & " DW=" & integer'image(G_DATA_WIDTH)
             & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE)
             & ": blocks=" & integer'image(G_MSG_BLOCKS)
             & " msg_bits=" & integer'image(c_MSG_BITS)
             & " input_span=" & integer'image(v_t_in - v_t0)
             & " total_cycles=" & integer'image(v_total)
             & " centibits_per_cycle=" & integer'image(v_cbpc);

        for i in 0 to 9 loop wait until rising_edge(clk); end loop;

        ------------------------------------------------------------------------
        -- Phase 2: short message (16 bytes) -- per-hash latency
        ------------------------------------------------------------------------
        for b in 0 to 16 / c_WB - 1 loop
            if b = 16 / c_WB - 1 then send_beat('1'); else send_beat('0'); end if;
            if b = 0 then v_t0 := r_cycle; end if;
        end loop;
        s_tvalid <= '0';
        s_tlast  <= '0';
        wait_tlast;

        report "LATENCY " & G_ALGORITHM & "-"
             & G_SHA3_VERSION & "/" & G_SHAKE_VERSION
             & " DW=" & integer'image(G_DATA_WIDTH)
             & " RPC=" & integer'image(G_ROUNDS_PER_CYCLE)
             & ": 16B msg, first-beat -> TLAST = "
             & integer'image(r_cycle - v_t0) & " cycles";

        done <= true;
        wait;
    end process;

end architecture;
