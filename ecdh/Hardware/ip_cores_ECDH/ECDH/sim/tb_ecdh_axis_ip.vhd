----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_ecdh_axis_ip
-- Module Name   : tb_ecdh_axis_ip - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Packet-level test for the full AXIS wrapper (deser + core + ser)
--                 For each vector (k,x,y -> xa,ya) and each backpressure pair it sends a KEYGEN
--                 packet (expects x||y on m_axis) and a SHARED packet (expects x on m_axis_z),
--                 checks TLAST framing and that the WRONG output stays silent (m_axis_z during
--                 KEYGEN, m_axis during SHARED). k arrives via side-band strobe. Backpressure
--                 pairs (valid% / ready%):
--                 100/100, 50/50, 30/70, 70/30, 90/10, 10/90   (pseudo-random, uniform seed).
--                 Vectors: gen_ladder_vectors.py (b FIXED = G_B).
--                 G_LOW_LATENCY selects the core in the DUT (true=ecdh_core_low_latency /
--                 false=ecdh_core_basic); results must match in both configurations -> run BOTH:
--                 ghdl -r --std=08 tb_ecdh_axis_ip -gG_M=4 -gDATA_WIDTH=8  -gG_LOW_LATENCY=false -gG_VEC_FILE=ladder_vec_gf4.txt
--                 ghdl -r --std=08 tb_ecdh_axis_ip -gG_M=4 -gDATA_WIDTH=8  -gG_LOW_LATENCY=true  -gG_VEC_FILE=ladder_vec_gf4.txt
--                 ghdl -r --std=08 tb_ecdh_axis_ip -gG_M=4 -gDATA_WIDTH=32 -gG_LOW_LATENCY=true  -gG_VEC_FILE=ladder_vec_gf4.txt
--                 ghdl -r --std=08 tb_ecdh_axis_ip -gG_M=571 -gG_D=32 -gDATA_WIDTH=32 -gG_BP=1 -gG_MAX_VEC=2 \
--                 -gG_LOW_LATENCY=true -gG_VEC_FILE=ladder_vec_b571_fixedb.txt
--
-- Revision      :
--   0.01 - August 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_ecdh_axis_ip is
    generic (
        G_M        : integer := 4;
        G_D        : integer := 1;
        DATA_WIDTH : integer := 8;
        G_BP       : integer := 6;      -- how many backpressure pairs to try (1..6)
        G_MAX_VEC  : integer := 999;    -- max vectors per pair (B-571: shorten)
        G_VEC_FILE : string  := "ladder_vec_gf4.txt";
        G_LOW_LATENCY : boolean := true  -- core in DUT: true=ecdh_core_low_latency, false=ecdh_core_basic
    );
end entity;

architecture sim of tb_ecdh_axis_ip is

    function f_poly(m : integer) return std_logic_vector is
        variable v : std_logic_vector(m downto 0) := (others => '0');
    begin
        v(m) := '1';
        if m = 4 then
            v(1) := '1'; v(0) := '1';
        elsif m = 571 then
            v(10) := '1'; v(5) := '1'; v(2) := '1'; v(0) := '1';
        else
            report "f_poly: unknown field m=" & integer'image(m) severity failure;
        end if;
        return v;
    end function;

    -- b FIXED (must match the vector file): GF(2^4) b=1; B-571 b=1
    function b_const(m : integer) return std_logic_vector is
        variable v : std_logic_vector(m-1 downto 0) := (others => '0');
    begin
        v(0) := '1';   -- b = 1
        return v;
    end function;

    constant C_N  : integer := (G_M + DATA_WIDTH - 1) / DATA_WIDTH;

    -- backpressure pairs: (valid%, ready%)
    type duty_t is array (0 to 1) of integer;
    type duty_arr_t is array (0 to 5) of duty_t;
    constant C_DUTY : duty_arr_t := (
        (100, 100), (50, 50), (30, 70), (70, 30), (90, 10), (10, 90) );

    signal clk    : std_logic := '0';
    signal rstn   : std_logic := '0';
    signal done_s : boolean   := false;

    signal k_side  : std_logic_vector(G_M-1 downto 0) := (others => '0');
    signal k_valid : std_logic := '0';

    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
    signal s_tkeep  : std_logic_vector(DATA_WIDTH/8-1 downto 0) := (others => '1');
    signal s_tlast  : std_logic := '0';

    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '0';
    signal m_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal m_tkeep  : std_logic_vector(DATA_WIDTH/8-1 downto 0);
    signal m_tlast  : std_logic;

    signal mz_tvalid : std_logic;
    signal mz_tready : std_logic := '0';
    signal mz_tdata  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mz_tkeep  : std_logic_vector(DATA_WIDTH/8-1 downto 0);
    signal mz_tlast  : std_logic;

    -- monitor: which output MAY be active (the other must stay silent)
    signal mon_keygen : boolean := false;   -- KEYGEN operation in progress
    signal mon_shared : boolean := false;   -- SHARED operation in progress

begin

    clk <= not clk after 5 ns when not done_s else '0';

    u_dut : entity work.ecdh_axis_ip
        generic map (G_M => G_M, G_D => G_D, G_F => f_poly(G_M),
                     G_B => b_const(G_M), DATA_WIDTH => DATA_WIDTH,
                     G_LOW_LATENCY => G_LOW_LATENCY)
        port map (
            i_clk => clk, i_resetn => rstn,
            i_k => k_side, i_k_valid => k_valid,
            s_axis_tvalid => s_tvalid, s_axis_tready => s_tready,
            s_axis_tdata => s_tdata, s_axis_tkeep => s_tkeep, s_axis_tlast => s_tlast,
            m_axis_tvalid => m_tvalid, m_axis_tready => m_tready,
            m_axis_tdata => m_tdata, m_axis_tkeep => m_tkeep, m_axis_tlast => m_tlast,
            m_axis_z_tvalid => mz_tvalid, m_axis_z_tready => mz_tready,
            m_axis_z_tdata => mz_tdata, m_axis_z_tkeep => mz_tkeep, m_axis_z_tlast => mz_tlast
        );

    -- the WRONG output must stay silent (security property + framing)
    p_MON_Z : process(clk)
    begin
        if rising_edge(clk) then
            if mon_keygen and mz_tvalid = '1' then
                report "SECRET output (m_axis_z) active during KEYGEN!" severity failure;
            end if;
            if mon_shared and m_tvalid = '1' then
                report "PUBLIC output (m_axis) active during SHARED!" severity failure;
            end if;
        end if;
    end process;

    p_main : process
        file     f_vec : text;
        variable l     : line;
        variable c     : character;
        variable ok    : boolean;
        variable vk, vx, vy, vb     : std_logic_vector(G_M-1 downto 0);
        variable vskip              : std_logic_vector(G_M-1 downto 0);
        variable exa, eya           : std_logic_vector(G_M-1 downto 0);
        variable seed1 : positive := 571;
        variable seed2 : positive := 1301;
        variable rnd   : real;
        variable n     : integer := 0;
        variable nfail : integer := 0;
        variable vi    : integer;

        procedure read_bits(variable ln : inout line;
                            v  : out std_logic_vector) is
            variable ch : character;
            variable okc : boolean;
        begin
            for i in v'range loop
                read(ln, ch, okc);
                assert okc report "short line in vector file" severity failure;
                if ch = '1' then v(i) := '1'; else v(i) := '0'; end if;
            end loop;
        end procedure;

        -- word idx (LSB-word-first) of a G_M-wide vector, zero-padded above G_M
        function word_of(v : std_logic_vector; idx : integer)
            return std_logic_vector is
            variable r : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
        begin
            for i in 0 to DATA_WIDTH-1 loop
                if idx*DATA_WIDTH + i <= G_M-1 then
                    r(i) := v(idx*DATA_WIDTH + i);
                end if;
            end loop;
            return r;
        end function;

        -- send one word on s_axis with the given valid duty
        procedure send_word(d : std_logic_vector; last : std_logic;
                            vduty : integer) is
        begin
            loop
                uniform(seed1, seed2, rnd);
                if rnd * 100.0 < real(vduty) then
                    s_tvalid <= '1'; s_tdata <= d; s_tlast <= last;
                else
                    s_tvalid <= '0';
                end if;
                wait until rising_edge(clk);
                exit when (s_tvalid = '1' and s_tready = '1');
            end loop;
            s_tvalid <= '0'; s_tlast <= '0';
        end procedure;

        -- send a whole packet: cmd, N words of Qx, N words of Qy (TLAST on the last)
        procedure send_pkt(is_shr : std_logic; qx, qy : std_logic_vector;
                           vduty : integer) is
            variable cmd  : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
            variable lst  : std_logic;
        begin
            cmd(0) := is_shr;
            send_word(cmd, '0', vduty);
            for j in 0 to C_N-1 loop
                send_word(word_of(qx, j), '0', vduty);
            end loop;
            for j in 0 to C_N-1 loop
                if j = C_N-1 then lst := '1'; else lst := '0'; end if;
                send_word(word_of(qy, j), lst, vduty);
            end loop;
        end procedure;

        -- receive a whole output packet (nwords words) from the selected master;
        -- TLAST must come exactly on the last word; words pack into a wide vector
        procedure recv_pkt(is_z : boolean; nwords : integer; rduty : integer;
                           variable acc : out std_logic_vector) is
            variable w   : std_logic_vector(DATA_WIDTH-1 downto 0);
            variable got : integer := 0;
            variable v   : std_logic_vector(2*C_N*DATA_WIDTH-1 downto 0) := (others => '0');
            variable lst : std_logic;
            variable hs  : boolean;
        begin
            while got < nwords loop
                uniform(seed1, seed2, rnd);
                if rnd * 100.0 < real(rduty) then
                    if is_z then mz_tready <= '1'; else m_tready <= '1'; end if;
                else
                    if is_z then mz_tready <= '0'; else m_tready <= '0'; end if;
                end if;
                wait until rising_edge(clk);
                if is_z then
                    hs := (mz_tready = '1' and mz_tvalid = '1');
                    w := mz_tdata; lst := mz_tlast;
                else
                    hs := (m_tready = '1' and m_tvalid = '1');
                    w := m_tdata; lst := m_tlast;
                end if;
                if hs then
                    v((got+1)*DATA_WIDTH-1 downto got*DATA_WIDTH) := w;
                    assert (lst = '1') = (got = nwords-1)
                        report "TLAST on wrong word" severity failure;
                    got := got + 1;
                end if;
            end loop;
            if is_z then mz_tready <= '0'; else m_tready <= '0'; end if;
            acc := v;
        end procedure;

        variable rwide    : std_logic_vector(2*C_N*DATA_WIDTH-1 downto 0);
        variable rx1, rx2 : std_logic_vector(G_M-1 downto 0);

    begin
        rstn <= '0';
        for i in 0 to 4 loop wait until rising_edge(clk); end loop;
        rstn <= '1';
        wait until rising_edge(clk);

        for dp in 0 to G_BP-1 loop
            file_open(f_vec, G_VEC_FILE, read_mode);
            vi := 0;
            while (not endfile(f_vec)) and vi < G_MAX_VEC loop
                readline(f_vec, l);
                next when l'length = 0;
                read_bits(l, vk);    read(l, c, ok);
                read_bits(l, vx);    read(l, c, ok);
                read_bits(l, vy);    read(l, c, ok);
                read_bits(l, vb);    read(l, c, ok);
                read_bits(l, vskip); read(l, c, ok);   -- X1
                read_bits(l, vskip); read(l, c, ok);   -- Z1
                read_bits(l, vskip); read(l, c, ok);   -- X2
                read_bits(l, vskip); read(l, c, ok);   -- Z2
                read_bits(l, exa);   read(l, c, ok);
                read_bits(l, eya);
                vi := vi + 1;

                -- k side-band strobe (before the packet)
                k_side <= vk; k_valid <= '1';
                wait until rising_edge(clk);
                k_valid <= '0';

                -- ---- KEYGEN: expect x||y (2N words) on m_axis ----
                mon_keygen <= true;
                send_pkt('0', vx, vy, C_DUTY(dp)(0));
                recv_pkt(false, 2*C_N, C_DUTY(dp)(1), rwide);
                rx1 := rwide(G_M-1 downto 0);                                  -- x
                rx2 := rwide(C_N*DATA_WIDTH + G_M-1 downto C_N*DATA_WIDTH);    -- y
                mon_keygen <= false;
                n := n + 1;
                if rx1 /= exa or rx2 /= eya then
                    nfail := nfail + 1;
                    if nfail <= 8 then
                        report "FAIL KEYGEN vec " & integer'image(vi-1)
                            & " pair " & integer'image(dp)
                            & " | x got=" & to_hstring(rx1) & " exp=" & to_hstring(exa)
                            & " | y got=" & to_hstring(rx2) & " exp=" & to_hstring(eya)
                            severity error;
                    end if;
                end if;

                -- ---- SHARED: expect x (N words) on m_axis_z ----
                mon_shared <= true;
                send_pkt('1', vx, vy, C_DUTY(dp)(0));
                recv_pkt(true, C_N, C_DUTY(dp)(1), rwide);
                rx1 := rwide(G_M-1 downto 0);                     -- x(S)
                mon_shared <= false;
                n := n + 1;
                if rx1 /= exa then
                    nfail := nfail + 1;
                    if nfail <= 8 then
                        report "FAIL SHARED vector " & integer'image(vi-1)
                            & " pair " & integer'image(dp) severity error;
                    end if;
                end if;
            end loop;
            file_close(f_vec);
        end loop;

        if nfail = 0 then
            report "==== ALL " & integer'image(n) & " PASS (m=" & integer'image(G_M)
                 & ", DW=" & integer'image(DATA_WIDTH) & ", pairs=" & integer'image(G_BP)
                 & ", LOW_LATENCY=" & boolean'image(G_LOW_LATENCY)
                 & ") ====";
        else
            report "==== " & integer'image(nfail) & "/" & integer'image(n)
                 & " FAIL (m=" & integer'image(G_M) & ") ====" severity failure;
        end if;

        done_s <= true;
        wait;
    end process;

end architecture;
