----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_gcm_loopback_src_dense
-- Module Name   : tb_gcm_loopback_src_dense - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : Encrypt -> decrypt loopback over many packets, with a rekey every
--                 G_REKEY_EVERY packets (exercising the shadow-key path and the H gate)
--                 and tamper injection. The recovered PT is scoreboarded against the
--                 golden PT, and the auth verdict must follow the tampering.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use std.textio.all;

entity tb_gcm_loopback_src_dense is
    generic (
        G_NUM_PACKETS   : integer  := 100;
        G_NUM_CORES     : integer  := 4;
        G_AES_BITS      : integer  := 128;
        G_WRAPPER_KIND  : string   := "MULTICORE";  -- "MULTICORE" or "UNROLLED"
        G_AAD_BEATS     : natural  := 0;
        G_REKEY_EVERY   : natural  := 0;            -- 0=off; k=new key every k packets
        G_SIZE_MODE     : string   := "STD";        -- "STD" {4..80} | "TINY" {1..4} | "BIG" {80}
        G_TAMPER        : boolean  := true;         -- tamper every 3rd packet
        G_IN_VALID_PCT  : integer  := 80;           -- ENC slave TVALID duty
        G_MID_READY_PCT : integer  := 80;           -- ENC master TREADY duty (FIFO fill)
        G_OUT_READY_PCT : integer  := 80;           -- DEC master TREADY duty
        G_SEED          : positive := 1
    );
end entity;

architecture sim of tb_gcm_loopback_src_dense is

    constant c_CLK_PERIOD : time    := 5 ns;
    constant c_DATA_WIDTH : integer := 128;

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';

    -- ENC side
    signal e_key         : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '0');
    signal e_key_valid   : std_logic := '0';
    signal e_nonce       : std_logic_vector(95 downto 0) := (others => '0');
    signal e_nonce_valid : std_logic := '0';
    signal e_s_tdata     : std_logic_vector(127 downto 0) := (others => '0');
    signal e_s_tkeep     : std_logic_vector(15 downto 0)  := (others => '1');
    signal e_s_tvalid    : std_logic := '0';
    signal e_s_tlast     : std_logic := '0';
    signal e_s_tready    : std_logic;
    signal e_m_tdata     : std_logic_vector(127 downto 0);
    signal e_m_tkeep     : std_logic_vector(15 downto 0);
    signal e_m_tvalid    : std_logic;
    signal e_m_tlast     : std_logic;
    signal e_m_tready    : std_logic := '0';

    -- DEC side
    signal d_key         : std_logic_vector(G_AES_BITS-1 downto 0) := (others => '0');
    signal d_key_valid   : std_logic := '0';
    signal d_nonce       : std_logic_vector(95 downto 0) := (others => '0');
    signal d_nonce_valid : std_logic := '0';
    signal d_s_tdata     : std_logic_vector(127 downto 0) := (others => '0');
    signal d_s_tkeep     : std_logic_vector(15 downto 0)  := (others => '1');
    signal d_s_tvalid    : std_logic := '0';
    signal d_s_tlast     : std_logic := '0';
    signal d_s_tready    : std_logic;
    signal d_m_tdata     : std_logic_vector(127 downto 0);
    signal d_m_tkeep     : std_logic_vector(15 downto 0);
    signal d_m_tvalid    : std_logic;
    signal d_m_tlast     : std_logic;
    signal d_m_tready    : std_logic := '0';

    signal d_auth_ok  : std_logic;
    signal d_dec_done : std_logic;

    signal start_stim : boolean := false;

    -- Sizes (CT beats per packet)
    type t_sizes is array (0 to 5) of integer;
    constant c_sizes : t_sizes := (4, 8, 16, 32, 64, 80);

    type t_size_arr is array (0 to G_NUM_PACKETS-1) of integer;
    shared variable sv_size : t_size_arr := (others => 0);

    -- ENC->DEC FIFO (large enough for the whole run if DEC lags)
    constant c_FIFO_DEPTH : integer := 16384;
    type t_fifo_data is array (0 to c_FIFO_DEPTH-1) of std_logic_vector(127 downto 0);
    type t_fifo_last is array (0 to c_FIFO_DEPTH-1) of std_logic;
    shared variable sv_fifo_data  : t_fifo_data;
    shared variable sv_fifo_last  : t_fifo_last := (others => '0');
    shared variable sv_fifo_head  : integer := 0;
    shared variable sv_fifo_tail  : integer := 0;
    shared variable sv_fifo_count : integer := 0;

    -- Scoreboard bookkeeping
    shared variable sv_dec_pkts   : integer := 0;  -- DEC packets completed
    shared variable sv_fail       : integer := 0;  -- failed packets
    shared variable sv_auth_seen  : integer := 0;  -- TLAST handshakes with dec_done

    constant c_in_prob  : real := real(G_IN_VALID_PCT)  / 100.0;
    constant c_mid_prob : real := real(G_MID_READY_PCT) / 100.0;
    constant c_out_prob : real := real(G_OUT_READY_PCT) / 100.0;

    constant c_BASE_NONCE : unsigned(95 downto 0) := x"deadbeefcafebabe11220000";

    ----------------------------------------------------------------------------
    -- Deterministic helpers shared by driver, tamper and scoreboard
    ----------------------------------------------------------------------------
    -- PT beat (pkt n, payload beat b)
    function pt_beat(n, b : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(n*256 + b, 128));
    end function;

    -- key for packet n (changes every G_REKEY_EVERY packets when enabled)
    function key_of(n : integer) return std_logic_vector is
        variable v_k : unsigned(G_AES_BITS-1 downto 0);
    begin
        v_k := resize(unsigned'(x"0123456789abcdef0123456789abcdef"),
                      G_AES_BITS);
        if G_REKEY_EVERY > 0 then
            v_k(31 downto 0) := to_unsigned(n / G_REKEY_EVERY, 32);
        end if;
        return std_logic_vector(v_k);
    end function;

    -- packet n is tampered?
    function is_tampered(n : integer) return boolean is
    begin
        return G_TAMPER and (n mod 3 = 1);
    end function;

    -- beat index (within the ENC OUTPUT packet: [AAD][CT..][ICV]) to corrupt
    function tamper_idx(n : integer) return integer is
        variable v_ord : integer;  -- ordinal of this tampered packet
        variable v_pos : integer;
    begin
        v_ord := (n - 1) / 3;
        if G_AAD_BEATS > 0 then
            v_pos := v_ord mod 4;          -- 0=AAD 1=firstCT 2=lastCT 3=ICV
        else
            v_pos := 1 + (v_ord mod 3);    -- 1=firstCT 2=lastCT 3=ICV
        end if;
        case v_pos is
            when 0      => return 0;
            when 1      => return G_AAD_BEATS;
            when 2      => return G_AAD_BEATS + sv_size(n) - 1;
            when others => return G_AAD_BEATS + sv_size(n);
        end case;
    end function;

begin

    p_CLK : process
    begin
        clk <= '0';
        wait for c_CLK_PERIOD / 2;
        clk <= '1';
        wait for c_CLK_PERIOD / 2;
    end process;

    u_enc : entity work.gcm_enc
        generic map (
            AES_BITS => G_AES_BITS, ROUND_STYLE => "LUT",
            WRAPPER_KIND => G_WRAPPER_KIND, NUM_CORES => G_NUM_CORES,
            AAD_BEATS => G_AAD_BEATS, DATA_WIDTH => c_DATA_WIDTH)
        port map (
            i_clk => clk, i_rstn => rstn,
            i_key => e_key, i_key_valid => e_key_valid,
            i_nonce => e_nonce, i_nonce_valid => e_nonce_valid,
            s_axis_tdata => e_s_tdata, s_axis_tkeep => e_s_tkeep,
            s_axis_tvalid => e_s_tvalid, s_axis_tlast => e_s_tlast,
            s_axis_tready => e_s_tready,
            m_axis_tdata => e_m_tdata, m_axis_tkeep => e_m_tkeep,
            m_axis_tvalid => e_m_tvalid, m_axis_tlast => e_m_tlast,
            m_axis_tready => e_m_tready);

    u_dec : entity work.gcm_dec
        generic map (
            AES_BITS => G_AES_BITS, ROUND_STYLE => "LUT",
            WRAPPER_KIND => G_WRAPPER_KIND, NUM_CORES => G_NUM_CORES,
            AAD_BEATS => G_AAD_BEATS, DATA_WIDTH => c_DATA_WIDTH)
        port map (
            i_clk => clk, i_rstn => rstn,
            i_key => d_key, i_key_valid => d_key_valid,
            i_nonce => d_nonce, i_nonce_valid => d_nonce_valid,
            s_axis_tdata => d_s_tdata, s_axis_tkeep => d_s_tkeep,
            s_axis_tvalid => d_s_tvalid, s_axis_tlast => d_s_tlast,
            s_axis_tready => d_s_tready,
            m_axis_tdata => d_m_tdata, m_axis_tkeep => d_m_tkeep,
            m_axis_tvalid => d_m_tvalid, m_axis_tlast => d_m_tlast,
            m_axis_tready => d_m_tready,
            o_auth_ok => d_auth_ok, o_dec_done => d_dec_done);

    ----------------------------------------------------------------------------
    -- ENC master TREADY: random throttle, gated by FIFO space
    ----------------------------------------------------------------------------
    p_ENC_TREADY : process
        variable v_s1 : positive := G_SEED + 111;
        variable v_s2 : positive := G_SEED * 5 + 3;
        variable v_r  : real;
    begin
        loop
            wait until rising_edge(clk);
            if rstn = '0' then
                e_m_tready <= '0';
            else
                uniform(v_s1, v_s2, v_r);
                if v_r < c_mid_prob and sv_fifo_count < c_FIFO_DEPTH - 2 then
                    e_m_tready <= '1';
                else
                    e_m_tready <= '0';
                end if;
            end if;
        end loop;
    end process;

    ----------------------------------------------------------------------------
    -- ENC sink -> FIFO, applying the tamper as beats fly by
    ----------------------------------------------------------------------------
    p_ENC_SINK : process(clk)
        variable v_pkt  : integer := 0;   -- ENC output packet index
        variable v_beat : integer := 0;   -- beat index inside it
        variable v_d    : std_logic_vector(127 downto 0);
    begin
        if rising_edge(clk) then
            if rstn = '1' and e_m_tvalid = '1' and e_m_tready = '1' then
                v_d := e_m_tdata;
                if v_pkt < G_NUM_PACKETS
                   and is_tampered(v_pkt) and v_beat = tamper_idx(v_pkt) then
                    v_d(0) := not v_d(0);
                end if;
                sv_fifo_data(sv_fifo_tail) := v_d;
                sv_fifo_last(sv_fifo_tail) := e_m_tlast;
                sv_fifo_tail  := (sv_fifo_tail + 1) mod c_FIFO_DEPTH;
                sv_fifo_count := sv_fifo_count + 1;
                if e_m_tlast = '1' then
                    v_pkt  := v_pkt + 1;
                    v_beat := 0;
                else
                    v_beat := v_beat + 1;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- DEC feeder: FIFO -> DEC slave with random TVALID; pulses the NEXT
    -- packet's DEC nonce near the tail of the packet being forwarded
    -- (mid-packet -> shadow register; occasionally lands on the flush cycle,
    -- which is exactly the window the swallow fixes protect).
    ----------------------------------------------------------------------------
    p_DEC_FEED : process(clk)
        variable v_s1   : positive := G_SEED + 777;
        variable v_s2   : positive := G_SEED * 7 + 5;
        variable v_r    : real;
        variable v_pkt  : integer := 0;  -- DEC input packet index
        variable v_beat : integer := 0;  -- beats forwarded in this packet
        variable v_tot  : integer;
        variable v_trig : integer;       -- nonce-pulse trigger beat
        variable v_init : boolean := false;  -- packet-0 nonce pulsed?
    begin
        if rising_edge(clk) then
            if rstn = '0' then
                d_s_tvalid    <= '0';
                d_s_tlast     <= '0';
                d_nonce_valid <= '0';
            else
                d_nonce_valid <= '0';
                d_key_valid   <= '0';

                -- packet-0 DEC key + nonce (idle apply); this process is the
                -- sole driver of d_key/d_nonce and their valids
                if not v_init then
                    d_key         <= key_of(0);
                    d_key_valid   <= '1';
                    d_nonce       <= std_logic_vector(c_BASE_NONCE);
                    d_nonce_valid <= '1';
                    v_init        := true;
                end if;

                if d_s_tvalid = '1' and d_s_tready = '1' then
                    -- beat consumed
                    sv_fifo_head  := (sv_fifo_head + 1) mod c_FIFO_DEPTH;
                    sv_fifo_count := sv_fifo_count - 1;
                    v_beat := v_beat + 1;

                    -- near-tail nonce (+ rekey-boundary key) pulse for the
                    -- NEXT packet
                    if v_pkt < G_NUM_PACKETS then
                        v_tot := G_AAD_BEATS + sv_size(v_pkt) + 1;
                        -- trigger beat: 2 before the end, but at least 1 so
                        -- single-CT-beat packets still pulse their successor
                        v_trig := v_tot - 2;
                        if v_trig < 1 then v_trig := 1; end if;
                        if v_beat = v_trig and v_pkt < G_NUM_PACKETS - 1 then
                            if G_REKEY_EVERY > 0
                               and ((v_pkt + 1) mod G_REKEY_EVERY = 0) then
                                d_key       <= key_of(v_pkt + 1);
                                d_key_valid <= '1';
                            end if;
                            d_nonce <= std_logic_vector(
                                c_BASE_NONCE + to_unsigned(v_pkt + 1, 32));
                            d_nonce_valid <= '1';
                        end if;
                        if v_beat = v_tot then
                            v_pkt  := v_pkt + 1;
                            v_beat := 0;
                        end if;
                    end if;
                    d_s_tvalid <= '0';
                    d_s_tlast  <= '0';
                end if;

                -- (re)present head of FIFO with throttle
                if (d_s_tvalid = '0' or (d_s_tvalid = '1' and d_s_tready = '1'))
                   and sv_fifo_count > 0 then
                    uniform(v_s1, v_s2, v_r);
                    if v_r < c_in_prob then
                        d_s_tdata  <= sv_fifo_data(sv_fifo_head);
                        d_s_tlast  <= sv_fifo_last(sv_fifo_head);
                        d_s_tvalid <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- DEC master TREADY: random throttle
    ----------------------------------------------------------------------------
    p_DEC_TREADY : process
        variable v_s1 : positive := G_SEED + 4242;
        variable v_s2 : positive := G_SEED * 3 + 7;
        variable v_r  : real;
    begin
        loop
            wait until rising_edge(clk);
            if rstn = '0' then
                d_m_tready <= '0';
            else
                uniform(v_s1, v_s2, v_r);
                if v_r < c_out_prob then d_m_tready <= '1';
                else                     d_m_tready <= '0'; end if;
            end if;
        end loop;
    end process;

    ----------------------------------------------------------------------------
    -- DEC scoreboard: bit-exact PT + AAD passthrough + auth verdict
    ----------------------------------------------------------------------------
    p_DEC_SINK : process(clk)
        variable v_pkt   : integer := 0;
        variable v_beat  : integer := 0;
        variable v_bad   : boolean := false;
        variable v_l     : line;
        constant c_ONES  : std_logic_vector(127 downto 0) := (others => '1');
    begin
        if rising_edge(clk) then
            if rstn = '1' and d_m_tvalid = '1' and d_m_tready = '1' then

                -- data check (clean packets only; tampered PT is meaningless)
                if v_pkt < G_NUM_PACKETS and not is_tampered(v_pkt) then
                    if v_beat < G_AAD_BEATS then
                        if d_m_tdata /= c_ONES then
                            v_bad := true;
                        end if;
                    elsif v_beat < G_AAD_BEATS + sv_size(v_pkt) then
                        if d_m_tdata /= pt_beat(v_pkt, v_beat - G_AAD_BEATS) then
                            v_bad := true;
                        end if;
                    else
                        v_bad := true;   -- beat overflow
                    end if;
                end if;

                if d_m_tlast = '1' then
                    -- auth verdict is valid here (dec_done level on last beat)
                    if d_dec_done = '1' then
                        sv_auth_seen := sv_auth_seen + 1;
                    else
                        v_bad := true;
                        write(v_l, string'("  pkt "));
                        write(v_l, v_pkt);
                        write(v_l, string'(": dec_done MISSING on TLAST"));
                        writeline(output, v_l);
                    end if;
                    if v_pkt < G_NUM_PACKETS then
                        if is_tampered(v_pkt) then
                            if d_auth_ok /= '0' then
                                v_bad := true;
                                write(v_l, string'("  pkt "));
                                write(v_l, v_pkt);
                                write(v_l, string'(": SECURITY FAIL - tampered packet ACCEPTED"));
                                writeline(output, v_l);
                            end if;
                        else
                            if d_auth_ok /= '1' then
                                v_bad := true;
                                write(v_l, string'("  pkt "));
                                write(v_l, v_pkt);
                                write(v_l, string'(": clean packet auth FAILED"));
                                writeline(output, v_l);
                            end if;
                        end if;
                        -- structural: AAD + size beats expected
                        if v_beat + 1 /= G_AAD_BEATS + sv_size(v_pkt) then
                            v_bad := true;
                            write(v_l, string'("  pkt "));
                            write(v_l, v_pkt);
                            write(v_l, string'(": beat count "));
                            write(v_l, v_beat + 1);
                            write(v_l, string'(" /= "));
                            write(v_l, G_AAD_BEATS + sv_size(v_pkt));
                            writeline(output, v_l);
                        end if;
                    end if;

                    if v_bad then
                        sv_fail := sv_fail + 1;
                    end if;
                    sv_dec_pkts := sv_dec_pkts + 1;
                    v_pkt  := v_pkt + 1;
                    v_beat := 0;
                    v_bad  := false;
                else
                    v_beat := v_beat + 1;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- PT source: dense streaming into ENC + near-tail ENC nonce pulses
    ----------------------------------------------------------------------------
    p_PT_SRC : process
        variable v_s1, v_s2 : positive;
        variable v_r        : real;
        variable v_idx      : integer;
        variable v_off      : integer;

        procedure send_beat(constant d : in std_logic_vector(127 downto 0);
                            constant last : in std_logic) is
        begin
            e_s_tdata <= d;
            e_s_tlast <= last;
            loop
                uniform(v_s1, v_s2, v_r);
                if v_r < c_in_prob then
                    e_s_tvalid <= '1';
                    wait until rising_edge(clk);
                    exit when e_s_tready = '1';
                else
                    e_s_tvalid <= '0';
                    wait until rising_edge(clk);
                end if;
            end loop;
        end procedure;

        -- nonce (and, on a rekey boundary, key) pulse for packet n
        procedure pulse_enc_iv(constant n : in integer) is
        begin
            e_s_tvalid    <= '0';     -- TB hygiene (no re-accept on this cycle)
            if n = 0 or (G_REKEY_EVERY > 0 and (n mod G_REKEY_EVERY = 0)) then
                e_key       <= key_of(n);
                e_key_valid <= '1';
            end if;
            e_nonce       <= std_logic_vector(c_BASE_NONCE + to_unsigned(n, 32));
            e_nonce_valid <= '1';
            wait until rising_edge(clk);
            e_key_valid   <= '0';
            e_nonce_valid <= '0';
        end procedure;
    begin
        v_s1 := G_SEED;
        v_s2 := G_SEED * 13 + 1;

        -- pick all sizes up front (shared with feeder + scoreboard)
        for n in 0 to G_NUM_PACKETS-1 loop
            uniform(v_s1, v_s2, v_r);
            if G_SIZE_MODE = "TINY" then
                -- boundary sizes: 1..4 beats (incl. single-beat packets)
                sv_size(n) := 1 + (integer(floor(v_r * 4.0)) mod 4);
            elsif G_SIZE_MODE = "BIG" then
                -- sustained max-size packets (GHASH backpressure soak)
                sv_size(n) := 80;
            else
                v_idx := integer(floor(v_r * real(c_sizes'length)));
                if v_idx > c_sizes'high then v_idx := c_sizes'high; end if;
                sv_size(n) := c_sizes(v_idx);
            end if;
        end loop;

        wait until start_stim;
        wait until rising_edge(clk);

        -- packet-0 ENC key + nonce (idle apply, same-cycle pulse); this
        -- process is the sole driver of e_key/e_nonce and their valids
        pulse_enc_iv(0);

        for n in 0 to G_NUM_PACKETS-1 loop
            -- wait for the CT pipeline to open
            for i in 1 to 4000 loop
                wait until rising_edge(clk);
                exit when e_s_tready = '1';
            end loop;
            assert e_s_tready = '1'
                report "DEADLOCK: ENC packet " & integer'image(n)
                     & " pipeline never opened" severity failure;

            -- AAD beats (all ones)
            for b in 0 to G_AAD_BEATS-1 loop
                send_beat((127 downto 0 => '1'), '0');
            end loop;

            -- near-tail trigger beat for the next ENC nonce
            uniform(v_s1, v_s2, v_r);
            v_off := sv_size(n) - 2 - integer(floor(v_r * 3.0));
            if v_off < 0 then v_off := 0; end if;

            for b in 0 to sv_size(n)-1 loop
                if b = sv_size(n)-1 then
                    send_beat(pt_beat(n, b), '1');
                else
                    send_beat(pt_beat(n, b), '0');
                end if;
                if n < G_NUM_PACKETS-1 and b = v_off then
                    pulse_enc_iv(n + 1);
                end if;
            end loop;
            e_s_tvalid <= '0';
            e_s_tlast  <= '0';
        end loop;
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Orchestrator
    ----------------------------------------------------------------------------
    p_ORCH : process
    begin
        report "==== tb_gcm_loopback_src_dense (" & G_WRAPPER_KIND
             & ", AAD=" & integer'image(G_AAD_BEATS)
             & ", seed=" & integer'image(G_SEED) & ") ====";

        rstn <= '0';
        wait for 50 ns;
        wait until rising_edge(clk);
        rstn <= '1';
        wait until rising_edge(clk);

        -- keys and nonces are pulsed by p_PT_SRC (ENC) and p_DEC_FEED (DEC),
        -- the sole drivers of the respective config ports.
        start_stim <= true;

        -- wait until the scoreboard has consumed every packet
        for i in 1 to 400000 loop
            wait until rising_edge(clk);
            exit when sv_dec_pkts >= G_NUM_PACKETS;
        end loop;

        report "==== Dense loopback result ====";
        report "DEC packets   : " & integer'image(sv_dec_pkts)
             & " / " & integer'image(G_NUM_PACKETS);
        report "auth verdicts : " & integer'image(sv_auth_seen);
        report "failed packets: " & integer'image(sv_fail);

        if sv_dec_pkts = G_NUM_PACKETS and sv_fail = 0
           and sv_auth_seen = G_NUM_PACKETS then
            report "PASS: dense loopback bit-exact, all tampered packets rejected";
        else
            report "FAIL: see per-packet messages above" severity failure;
        end if;

        wait for 20 * c_CLK_PERIOD;
        finish(0);
    end process;

    p_TIMEOUT : process
    begin
        wait for 20 ms;
        report "Hard timeout (consistent with a deadlock)" severity failure;
        finish(1);
    end process;

end architecture;
