----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_key_chain
-- Module Name   : tb_key_chain - sim
-- Tool Version  : Vivado Simulator 2025.1 (xvhdl -2008 / xelab / xsim)
--
-- Description   : Simulation of the complete key-derivation-and-use chain of
--                 the thesis (fig:hw_lanac), played out between two parties:
--
--                   1. ECDH    : side A (scalar d_A) and side B (scalar d_B)
--                                each compute their public key on their own
--                                ecdh_axis_ip core (KEYGEN, base point of
--                                NIST B-571); the testbench carries the
--                                public keys across, and each side computes
--                                the shared secret (SHARED). Z arrives on
--                                m_axis_z and must match on both sides and
--                                match the ec_ladder.py golden model.
--                   2. KMAC KDF: the testbench plays the frame control logic
--                                of the figure: it feeds each side's SHA-3
--                                core (ALGORITHM = CSHAKE) the KMAC frame of
--                                thesis example 3.1 -- prefix block
--                                (N = "KMAC", S = "KDF" per SP 800-56C), the
--                                salt block, then Z relayed word-for-word
--                                from m_axis_z, then FixedInfo and
--                                right_encode(256). Both sides must derive
--                                the same 256-bit session key K, equal to
--                                the Python reference.
--                   3. AES-GCM : K drives the key ports of the ipsec GCM
--                                tops. A protects a packet that B receives
--                                (round-trip byte-identical, tag verified),
--                                then B answers A with a different nonce.
--                                The protected packets on the wire must also
--                                match the AES-256-GCM reference.
--
--                 Every hand-off is the previous core's output accepted
--                 unmodified at the next core's input: Q_A/Q_B are replayed
--                 exactly as received, Z words go to SHA-3 verbatim, and K is
--                 the assembled SHA-3 output stream. All golden constants
--                 come from tb_key_chain_vectors_pkg (generated and
--                 cross-validated by ref/gen_key_chain_vectors.py).
--
-- Dependencies  : work.tb_key_chain_vectors_pkg, work.ecdh_axis_ip,
--                 work.sha3_axis_ip, work.ipsec_gcm_enc_top,
--                 work.ipsec_gcm_dec_top
--
-- Revision      :
--   0.01 - August 2026 - File Created
--
-- Additional Comments :
--   Functional demonstration, not a performance run: streams run without
--   random backpressure (each core's own suite already proves that) and the
--   AES wrapper is a light MULTICORE configuration, because throughput plays
--   no role here. G_ECDH_D = 64 with the low-latency core keeps one kP at
--   about 16k cycles, the fastest measured configuration.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.tb_key_chain_vectors_pkg.all;

entity tb_key_chain is
    generic (
        G_ECDH_D        : integer := 64;     -- ECDH digit width (latency knob)
        G_ECDH_LOW_LAT  : boolean := true;   -- true = ecdh_core_low_latency
        G_NUM_CORES     : integer := 4;      -- AES MULTICORE size (functional)
        G_MULT_CYCLES   : integer := 1       -- GHASH multiply timing
    );
end entity;

architecture sim of tb_key_chain is

    ----------------------------------------------------------------------------
    -- Geometry
    ----------------------------------------------------------------------------
    constant c_EC_M     : integer := 571;                 -- field width (B-571)
    constant c_EC_DW    : integer := 32;                  -- ECDH/SHA-3 AXIS width
    constant c_EC_WORDS : integer := (c_EC_M + c_EC_DW - 1) / c_EC_DW;
                          -- words per field element: ceil(571/32) = 18
    constant c_AES_DW   : integer := 128;                 -- GCM chain AXIS width
    constant c_AES_LANES: integer := c_AES_DW / 8;

    constant c_HEAD_WORDS : integer := C_FRAME_HEAD_BYTES / 4;   -- 272 / 4 = 68
    constant c_KEY_WORDS  : integer := 256 / c_EC_DW;            -- 8

    -- NIST B-571 reduction polynomial x^571 + x^10 + x^5 + x^2 + 1,
    -- WITH the leading bit, as the G_F generic expects.
    function f_poly_b571 return std_logic_vector is
        variable v : std_logic_vector(c_EC_M downto 0) := (others => '0');
    begin
        v(c_EC_M) := '1';
        v(10) := '1';
        v(5)  := '1';
        v(2)  := '1';
        v(0)  := '1';
        return v;
    end function;

    constant c_EC_F : std_logic_vector(c_EC_M downto 0) := f_poly_b571;

    ----------------------------------------------------------------------------
    -- Two-sided signal bundles: index 0 = side A, index 1 = side B
    ----------------------------------------------------------------------------
    type side_word_arr_t is array (0 to 1) of std_logic_vector(c_EC_DW - 1 downto 0);
    type side_keep_arr_t is array (0 to 1) of std_logic_vector(c_EC_DW / 8 - 1 downto 0);
    type side_bit_arr_t  is array (0 to 1) of std_logic;
    type side_k_arr_t    is array (0 to 1) of std_logic_vector(c_EC_M - 1 downto 0);

    signal clk  : std_logic := '0';
    signal rstn : std_logic := '0';
    signal done : boolean   := false;

    -- ECDH private scalar side-band
    signal ecdh_k       : side_k_arr_t   := (others => (others => '0'));
    signal ecdh_k_valid : side_bit_arr_t := (others => '0');

    -- ECDH s_axis (operand packet cmd || Qx || Qy)
    signal ecdh_s_tdata  : side_word_arr_t := (others => (others => '0'));
    signal ecdh_s_tkeep  : side_keep_arr_t := (others => (others => '1'));
    signal ecdh_s_tvalid : side_bit_arr_t  := (others => '0');
    signal ecdh_s_tlast  : side_bit_arr_t  := (others => '0');
    signal ecdh_s_tready : side_bit_arr_t;

    -- ECDH m_axis (public result x || y)
    signal ecdh_m_tdata  : side_word_arr_t;
    signal ecdh_m_tkeep  : side_keep_arr_t;
    signal ecdh_m_tvalid : side_bit_arr_t;
    signal ecdh_m_tlast  : side_bit_arr_t;
    signal ecdh_m_tready : side_bit_arr_t := (others => '0');

    -- ECDH m_axis_z (secret x(S), goes to the KDF)
    signal ecdh_z_tdata  : side_word_arr_t;
    signal ecdh_z_tkeep  : side_keep_arr_t;
    signal ecdh_z_tvalid : side_bit_arr_t;
    signal ecdh_z_tlast  : side_bit_arr_t;
    signal ecdh_z_tready : side_bit_arr_t := (others => '0');

    -- SHA-3 s_axis (KMAC-framed message)
    signal sha3_s_tdata  : side_word_arr_t := (others => (others => '0'));
    signal sha3_s_tkeep  : side_keep_arr_t := (others => (others => '0'));
    signal sha3_s_tvalid : side_bit_arr_t  := (others => '0');
    signal sha3_s_tlast  : side_bit_arr_t  := (others => '0');
    signal sha3_s_tready : side_bit_arr_t;

    -- SHA-3 m_axis (the derived session key K)
    signal sha3_m_tdata  : side_word_arr_t;
    signal sha3_m_tkeep  : side_keep_arr_t;
    signal sha3_m_tvalid : side_bit_arr_t;
    signal sha3_m_tlast  : side_bit_arr_t;
    signal sha3_m_tready : side_bit_arr_t := (others => '0');

    ----------------------------------------------------------------------------
    -- AES-GCM: one enc/dec pair per direction, keyed per side
    ----------------------------------------------------------------------------
    signal aes_key_a     : std_logic_vector(255 downto 0) := (others => '0');
    signal aes_key_b     : std_logic_vector(255 downto 0) := (others => '0');
    signal aes_cfg_valid : std_logic := '0';

    type dir_data_arr_t is array (0 to 1) of std_logic_vector(c_AES_DW - 1 downto 0);
    type dir_keep_arr_t is array (0 to 1) of std_logic_vector(c_AES_LANES - 1 downto 0);
    type dir_bit_arr_t  is array (0 to 1) of std_logic;
    type dir_key_arr_t  is array (0 to 1) of std_logic_vector(255 downto 0);
    type dir_nonce_arr_t is array (0 to 1) of std_logic_vector(95 downto 0);
    type dir_int_arr_t  is array (0 to 1) of integer;

    -- direction index: 0 = A -> B (enc keyed by A, dec keyed by B), 1 = B -> A
    constant c_NONCES : dir_nonce_arr_t := (C_NONCE_AB, C_NONCE_BA);

    -- per-direction key selection: the encryptor holds the sender's key and
    -- the decryptor the receiver's, so agreement of the two derivations is
    -- what the round-trip actually proves
    signal aes_enc_key : dir_key_arr_t;
    signal aes_dec_key : dir_key_arr_t;

    -- plain packet into the encryptor
    signal aes_s_tdata  : dir_data_arr_t := (others => (others => '0'));
    signal aes_s_tkeep  : dir_keep_arr_t := (others => (others => '0'));
    signal aes_s_tvalid : dir_bit_arr_t  := (others => '0');
    signal aes_s_tlast  : dir_bit_arr_t  := (others => '0');
    signal aes_s_tready : dir_bit_arr_t;

    -- protected packet on the wire (encryptor -> decryptor, tapped by monitors)
    signal prot_tdata  : dir_data_arr_t;
    signal prot_tkeep  : dir_keep_arr_t;
    signal prot_tvalid : dir_bit_arr_t;
    signal prot_tlast  : dir_bit_arr_t;
    signal prot_tready : dir_bit_arr_t;

    -- recovered packet out of the decryptor
    signal aes_m_tdata  : dir_data_arr_t;
    signal aes_m_tkeep  : dir_keep_arr_t;
    signal aes_m_tvalid : dir_bit_arr_t;
    signal aes_m_tlast  : dir_bit_arr_t;
    signal aes_m_tready : dir_bit_arr_t := (others => '0');

    signal aes_auth_ok  : dir_bit_arr_t;
    signal aes_dec_done : dir_bit_arr_t;

    -- sticky per-direction capture of the decryptor's tag verdict
    signal auth_seen : dir_bit_arr_t := (others => '0');

    -- protected-packet monitor verdicts (compared against the Python reference)
    signal mon_done   : dir_bit_arr_t := (others => '0');
    signal mon_errors : dir_int_arr_t := (others => 0);

    -- total clock cycles from reset release to the final report
    signal r_cycles : integer := 0;

begin

    clk  <= not clk after 5 ns when not done else '0';
    rstn <= '0', '1' after 33 ns;

    p_CYCLES : process (clk)
    begin
        if rising_edge(clk) then
            if rstn = '1' and not done then
                r_cycles <= r_cycles + 1;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Two ECDH cores, one per party (identical configuration)
    ----------------------------------------------------------------------------
    gen_ecdh : for side in 0 to 1 generate
        u_ecdh : entity work.ecdh_axis_ip
            generic map (
                G_M           => c_EC_M,
                G_D           => G_ECDH_D,
                G_F           => c_EC_F,
                G_B           => C_CURVE_B,
                DATA_WIDTH    => c_EC_DW,
                G_LOW_LATENCY => G_ECDH_LOW_LAT
            )
            port map (
                i_clk    => clk,
                i_resetn => rstn,

                i_k       => ecdh_k(side),
                i_k_valid => ecdh_k_valid(side),

                s_axis_tvalid => ecdh_s_tvalid(side),
                s_axis_tready => ecdh_s_tready(side),
                s_axis_tdata  => ecdh_s_tdata(side),
                s_axis_tkeep  => ecdh_s_tkeep(side),
                s_axis_tlast  => ecdh_s_tlast(side),

                m_axis_tvalid => ecdh_m_tvalid(side),
                m_axis_tready => ecdh_m_tready(side),
                m_axis_tdata  => ecdh_m_tdata(side),
                m_axis_tkeep  => ecdh_m_tkeep(side),
                m_axis_tlast  => ecdh_m_tlast(side),

                m_axis_z_tvalid => ecdh_z_tvalid(side),
                m_axis_z_tready => ecdh_z_tready(side),
                m_axis_z_tdata  => ecdh_z_tdata(side),
                m_axis_z_tkeep  => ecdh_z_tkeep(side),
                m_axis_z_tlast  => ecdh_z_tlast(side)
            );
    end generate gen_ecdh;

    ----------------------------------------------------------------------------
    -- Two SHA-3 cores in the cSHAKE (KMAC) configuration, L = 256 bits
    ----------------------------------------------------------------------------
    gen_sha3 : for side in 0 to 1 generate
        u_sha3 : entity work.sha3_axis_ip
            generic map (
                ALGORITHM        => "CSHAKE",
                SHAKE_VERSION    => "256",
                SHAKE_BITS       => 256,
                DATA_WIDTH       => c_EC_DW,
                ROUNDS_PER_CYCLE => 1
            )
            port map (
                axis_aclk    => clk,
                axis_aresetn => rstn,

                s_axis_tvalid => sha3_s_tvalid(side),
                s_axis_tready => sha3_s_tready(side),
                s_axis_tdata  => sha3_s_tdata(side),
                s_axis_tkeep  => sha3_s_tkeep(side),
                s_axis_tlast  => sha3_s_tlast(side),

                m_axis_tvalid => sha3_m_tvalid(side),
                m_axis_tready => sha3_m_tready(side),
                m_axis_tdata  => sha3_m_tdata(side),
                m_axis_tkeep  => sha3_m_tkeep(side),
                m_axis_tlast  => sha3_m_tlast(side)
            );
    end generate gen_sha3;

    ----------------------------------------------------------------------------
    -- AES-GCM chain, one encrypt/decrypt pair per direction. Direction 0 is
    -- A -> B: the encryptor holds A's derived key, the decryptor B's, so the
    -- round-trip can only succeed if the two independently derived keys agree.
    ----------------------------------------------------------------------------
    aes_enc_key(0) <= aes_key_a;
    aes_enc_key(1) <= aes_key_b;
    aes_dec_key(0) <= aes_key_b;
    aes_dec_key(1) <= aes_key_a;

    gen_gcm : for dir in 0 to 1 generate
        u_enc : entity work.ipsec_gcm_enc_top
            generic map (
                DATA_WIDTH   => c_AES_DW,
                BYPASS_EN    => true,
                BYPASS_BYTES => C_BYPASS_BYTES,
                AAD_BYTES    => C_AAD_BYTES,
                MULT_CYCLES  => G_MULT_CYCLES,
                AES_BITS     => 256,
                ROUND_STYLE  => "LUT",
                FLOW_STYLE   => "GLOBAL",
                WRAPPER_KIND => "MULTICORE",
                NUM_CORES    => G_NUM_CORES
            )
            port map (
                i_clk  => clk,
                i_rstn => rstn,

                i_key         => aes_enc_key(dir),
                i_key_valid   => aes_cfg_valid,
                i_nonce       => c_NONCES(dir),
                i_nonce_valid => aes_cfg_valid,

                s_axis_tdata  => aes_s_tdata(dir),
                s_axis_tkeep  => aes_s_tkeep(dir),
                s_axis_tvalid => aes_s_tvalid(dir),
                s_axis_tlast  => aes_s_tlast(dir),
                s_axis_tready => aes_s_tready(dir),

                m_axis_tdata  => prot_tdata(dir),
                m_axis_tkeep  => prot_tkeep(dir),
                m_axis_tvalid => prot_tvalid(dir),
                m_axis_tlast  => prot_tlast(dir),
                m_axis_tready => prot_tready(dir),

                o_ENC_in_proc => open,
                o_TxENC       => open
            );

        u_dec : entity work.ipsec_gcm_dec_top
            generic map (
                DATA_WIDTH   => c_AES_DW,
                BYPASS_EN    => true,
                BYPASS_BYTES => C_BYPASS_BYTES,
                AAD_BYTES    => C_AAD_BYTES,
                MULT_CYCLES  => G_MULT_CYCLES,
                AES_BITS     => 256,
                ROUND_STYLE  => "LUT",
                FLOW_STYLE   => "GLOBAL",
                WRAPPER_KIND => "MULTICORE",
                NUM_CORES    => G_NUM_CORES
            )
            port map (
                i_clk  => clk,
                i_rstn => rstn,

                i_key         => aes_dec_key(dir),
                i_key_valid   => aes_cfg_valid,
                i_nonce       => c_NONCES(dir),
                i_nonce_valid => aes_cfg_valid,

                s_axis_tdata  => prot_tdata(dir),
                s_axis_tkeep  => prot_tkeep(dir),
                s_axis_tvalid => prot_tvalid(dir),
                s_axis_tlast  => prot_tlast(dir),
                s_axis_tready => prot_tready(dir),

                m_axis_tdata  => aes_m_tdata(dir),
                m_axis_tkeep  => aes_m_tkeep(dir),
                m_axis_tvalid => aes_m_tvalid(dir),
                m_axis_tlast  => aes_m_tlast(dir),
                m_axis_tready => aes_m_tready(dir),

                o_auth_ok     => aes_auth_ok(dir),
                o_dec_done    => aes_dec_done(dir),
                o_DEC_in_proc => open
            );
    end generate gen_gcm;

    ----------------------------------------------------------------------------
    -- Sticky capture of each decryptor's tag verdict
    ----------------------------------------------------------------------------
    p_AUTH : process (clk)
    begin
        if rising_edge(clk) then
            for dir in 0 to 1 loop
                if rstn = '0' then
                    auth_seen(dir) <= '0';
                elsif aes_auth_ok(dir) = '1' then
                    auth_seen(dir) <= '1';
                end if;
            end loop;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Wire monitors: the protected packet between encryptor and decryptor
    -- must equal the AES-256-GCM Python reference byte-for-byte. The monitor
    -- only taps the stream; the hand-off itself is a direct wire.
    ----------------------------------------------------------------------------
    gen_mon : for dir in 0 to 1 generate
        p_MON_PROT : process
            constant c_EXP_LEN : integer :=
                C_BYPASS_BYTES + C_AAD_BYTES + C_ICV_BYTES
                + (C_PT_AB_BYTES * (1 - dir)) + (C_PT_BA_BYTES * dir);
            variable v_cnt  : integer := 0;
            variable v_bad  : integer := 0;
            variable v_byte : std_logic_vector(7 downto 0);
            variable v_exp  : std_logic_vector(7 downto 0);
        begin
            wait until rstn = '1';
            loop
                wait until rising_edge(clk);
                if prot_tvalid(dir) = '1' and prot_tready(dir) = '1' then
                    for lane in 0 to c_AES_LANES - 1 loop
                        if prot_tkeep(dir)(lane) = '1' then
                            v_byte := prot_tdata(dir)(8 * lane + 7 downto 8 * lane);
                            if v_cnt < c_EXP_LEN then
                                if dir = 0 then
                                    v_exp := C_PROT_AB(v_cnt);
                                else
                                    v_exp := C_PROT_BA(v_cnt);
                                end if;
                                if v_byte /= v_exp then
                                    if v_bad < 8 then
                                        report "PROT dir " & integer'image(dir)
                                             & " byte " & integer'image(v_cnt)
                                             & ": got " & to_hstring(v_byte)
                                             & " expected " & to_hstring(v_exp)
                                            severity error;
                                    end if;
                                    v_bad := v_bad + 1;
                                end if;
                            end if;
                            v_cnt := v_cnt + 1;
                        end if;
                    end loop;
                    if prot_tlast(dir) = '1' then
                        exit;
                    end if;
                end if;
            end loop;
            if v_cnt /= c_EXP_LEN then
                report "PROT dir " & integer'image(dir) & " length "
                     & integer'image(v_cnt) & ", expected "
                     & integer'image(c_EXP_LEN) severity error;
                v_bad := v_bad + 1;
            end if;
            if v_bad = 0 then
                report "PROTECTED PACKET dir " & integer'image(dir)
                     & " matches the AES-256-GCM reference ("
                     & integer'image(v_cnt) & " bytes)";
            end if;
            mon_errors(dir) <= v_bad;
            mon_done(dir) <= '1';
            wait;
        end process;
    end generate gen_mon;

    ----------------------------------------------------------------------------
    -- The chain scenario, one sequential story
    ----------------------------------------------------------------------------
    p_MAIN : process
        variable v_errors : integer := 0;

        -- one word of a wide field element, LSB word first, zero-padded on top
        function word_of (v : std_logic_vector(c_EC_M - 1 downto 0);
                          idx : integer) return std_logic_vector is
            variable r : std_logic_vector(c_EC_DW - 1 downto 0) := (others => '0');
        begin
            for i in 0 to c_EC_DW - 1 loop
                if idx * c_EC_DW + i <= c_EC_M - 1 then
                    r(i) := v(idx * c_EC_DW + i);
                end if;
            end loop;
            return r;
        end function;

        -- one word of the KMAC frame head, byte 0 of the word on tdata(7:0)
        function head_word (idx : integer) return std_logic_vector is
            variable r : std_logic_vector(c_EC_DW - 1 downto 0);
        begin
            for j in 0 to 3 loop
                r(8 * j + 7 downto 8 * j) := C_FRAME_HEAD(idx * 4 + j);
            end loop;
            return r;
        end function;

        -- send one word into an ECDH slave interface
        procedure ecdh_send_word (side : integer;
                                  data : std_logic_vector(c_EC_DW - 1 downto 0);
                                  last : std_logic) is
        begin
            ecdh_s_tdata(side)  <= data;
            ecdh_s_tvalid(side) <= '1';
            ecdh_s_tlast(side)  <= last;
            loop
                wait until rising_edge(clk);
                exit when ecdh_s_tready(side) = '1';
            end loop;
            ecdh_s_tvalid(side) <= '0';
            ecdh_s_tlast(side)  <= '0';
        end procedure;

        -- send a whole operand packet: cmd, 18 words Qx, 18 words Qy
        procedure ecdh_send_pkt (side : integer; is_shared : std_logic;
                                 qx, qy : std_logic_vector(c_EC_M - 1 downto 0)) is
            variable v_cmd : std_logic_vector(c_EC_DW - 1 downto 0) := (others => '0');
        begin
            v_cmd(0) := is_shared;
            ecdh_send_word(side, v_cmd, '0');
            for j in 0 to c_EC_WORDS - 1 loop
                ecdh_send_word(side, word_of(qx, j), '0');
            end loop;
            for j in 0 to c_EC_WORDS - 1 loop
                if j = c_EC_WORDS - 1 then
                    ecdh_send_word(side, word_of(qy, j), '1');
                else
                    ecdh_send_word(side, word_of(qy, j), '0');
                end if;
            end loop;
        end procedure;

        -- collect the KEYGEN result x || y from m_axis (36 words)
        procedure ecdh_recv_pub (side : integer;
                                 variable qx, qy : out std_logic_vector(c_EC_M - 1 downto 0);
                                 label_str : string) is
            variable v_wide  : std_logic_vector(2 * c_EC_WORDS * c_EC_DW - 1 downto 0);
            variable v_got   : integer := 0;
            variable v_guard : integer := 0;
        begin
            ecdh_m_tready(side) <= '1';
            while v_got < 2 * c_EC_WORDS loop
                wait until rising_edge(clk);
                if ecdh_m_tvalid(side) = '1' then
                    v_wide((v_got + 1) * c_EC_DW - 1 downto v_got * c_EC_DW)
                        := ecdh_m_tdata(side);
                    if (ecdh_m_tlast(side) = '1') /= (v_got = 2 * c_EC_WORDS - 1) then
                        report label_str & ": TLAST on the wrong word" severity error;
                        v_errors := v_errors + 1;
                    end if;
                    v_got := v_got + 1;
                end if;
                v_guard := v_guard + 1;
                assert v_guard < 3_000_000
                    report label_str & ": TIMEOUT waiting for the public key"
                    severity failure;
            end loop;
            ecdh_m_tready(side) <= '0';
            qx := v_wide(c_EC_M - 1 downto 0);
            qy := v_wide(c_EC_WORDS * c_EC_DW + c_EC_M - 1 downto c_EC_WORDS * c_EC_DW);
        end procedure;

        -- send one word into a SHA-3 slave interface
        procedure sha3_send_word (side : integer;
                                  data : std_logic_vector(c_EC_DW - 1 downto 0);
                                  keep : std_logic_vector(c_EC_DW / 8 - 1 downto 0);
                                  last : std_logic) is
            variable v_guard : integer := 0;
        begin
            sha3_s_tdata(side)  <= data;
            sha3_s_tkeep(side)  <= keep;
            sha3_s_tvalid(side) <= '1';
            sha3_s_tlast(side)  <= last;
            loop
                wait until rising_edge(clk);
                exit when sha3_s_tready(side) = '1';
                v_guard := v_guard + 1;
                assert v_guard < 10_000
                    report "SHA-3 side " & integer'image(side)
                         & ": TIMEOUT on s_axis_tready" severity failure;
            end loop;
            sha3_s_tvalid(side) <= '0';
            sha3_s_tlast(side)  <= '0';
            sha3_s_tkeep(side)  <= (others => '0');
        end procedure;

        -- relay Z from m_axis_z to the SHA-3 core word-for-word, keep a copy
        procedure relay_z (side : integer;
                           variable z : out std_logic_vector(c_EC_M - 1 downto 0);
                           label_str : string) is
            variable v_word  : std_logic_vector(c_EC_DW - 1 downto 0);
            variable v_acc   : std_logic_vector(c_EC_WORDS * c_EC_DW - 1 downto 0);
            variable v_got   : integer := 0;
            variable v_guard : integer := 0;
        begin
            while v_got < c_EC_WORDS loop
                ecdh_z_tready(side) <= '1';
                loop
                    wait until rising_edge(clk);
                    exit when ecdh_z_tvalid(side) = '1';
                    v_guard := v_guard + 1;
                    assert v_guard < 3_000_000
                        report label_str & ": TIMEOUT waiting for Z" severity failure;
                end loop;
                v_word := ecdh_z_tdata(side);
                if (ecdh_z_tlast(side) = '1') /= (v_got = c_EC_WORDS - 1) then
                    report label_str & ": TLAST on the wrong Z word" severity error;
                    v_errors := v_errors + 1;
                end if;
                ecdh_z_tready(side) <= '0';
                v_acc((v_got + 1) * c_EC_DW - 1 downto v_got * c_EC_DW) := v_word;
                v_got := v_got + 1;
                -- the hand-off of the figure: the secret output word goes to
                -- the SHA-3 input exactly as received
                sha3_send_word(side, v_word, (others => '1'), '0');
            end loop;
            z := v_acc(c_EC_M - 1 downto 0);
        end procedure;

        -- send the KMAC frame tail: FixedInfo, then right_encode(L) in a
        -- partial last beat (43 bytes = 10 whole words + 3 bytes)
        procedure send_tail (side : integer) is
            variable v_word : std_logic_vector(c_EC_DW - 1 downto 0);
            variable v_keep : std_logic_vector(c_EC_DW / 8 - 1 downto 0);
            variable v_idx  : integer;
        begin
            for w in 0 to (C_FRAME_TAIL_BYTES + 3) / 4 - 1 loop
                v_word := (others => '0');
                v_keep := (others => '0');
                for j in 0 to 3 loop
                    v_idx := w * 4 + j;
                    if v_idx < C_FRAME_TAIL_BYTES then
                        v_word(8 * j + 7 downto 8 * j) := C_FRAME_TAIL(v_idx);
                        v_keep(j) := '1';
                    end if;
                end loop;
                if (w + 1) * 4 >= C_FRAME_TAIL_BYTES then
                    sha3_send_word(side, v_word, v_keep, '1');
                else
                    sha3_send_word(side, v_word, v_keep, '0');
                end if;
            end loop;
        end procedure;

        -- collect the 256-bit key K in spec order (first byte in bits 255:248)
        procedure sha3_recv_key (side : integer;
                                 variable key : out std_logic_vector(255 downto 0);
                                 label_str : string) is
            variable v_word  : integer := 0;
            variable v_idx   : integer;
            variable v_guard : integer := 0;
        begin
            sha3_m_tready(side) <= '1';
            while v_word < c_KEY_WORDS loop
                wait until rising_edge(clk);
                if sha3_m_tvalid(side) = '1' then
                    for j in 0 to 3 loop
                        v_idx := v_word * 4 + j;
                        key(255 - 8 * v_idx downto 248 - 8 * v_idx)
                            := sha3_m_tdata(side)(8 * j + 7 downto 8 * j);
                    end loop;
                    if (sha3_m_tlast(side) = '1') /= (v_word = c_KEY_WORDS - 1) then
                        report label_str & ": TLAST on the wrong key word"
                            severity error;
                        v_errors := v_errors + 1;
                    end if;
                    v_word := v_word + 1;
                end if;
                v_guard := v_guard + 1;
                assert v_guard < 10_000
                    report label_str & ": TIMEOUT waiting for the session key"
                    severity failure;
            end loop;
            sha3_m_tready(side) <= '0';
        end procedure;

        -- stream one plain packet into an encryptor (full beats + partial tail)
        procedure aes_send_pkt (dir : integer; pkt : byte_arr_t) is
            constant c_BEATS : integer := (pkt'length + c_AES_LANES - 1) / c_AES_LANES;
            variable v_data  : std_logic_vector(c_AES_DW - 1 downto 0);
            variable v_keep  : std_logic_vector(c_AES_LANES - 1 downto 0);
            variable v_idx   : integer;
            variable v_guard : integer := 0;
        begin
            for n in 0 to c_BEATS - 1 loop
                v_data := (others => '0');
                v_keep := (others => '0');
                for lane in 0 to c_AES_LANES - 1 loop
                    v_idx := n * c_AES_LANES + lane;
                    if v_idx < pkt'length then
                        v_data(8 * lane + 7 downto 8 * lane) := pkt(v_idx);
                        v_keep(lane) := '1';
                    end if;
                end loop;
                aes_s_tdata(dir)  <= v_data;
                aes_s_tkeep(dir)  <= v_keep;
                aes_s_tvalid(dir) <= '1';
                if n = c_BEATS - 1 then
                    aes_s_tlast(dir) <= '1';
                else
                    aes_s_tlast(dir) <= '0';
                end if;
                loop
                    wait until rising_edge(clk);
                    exit when aes_s_tready(dir) = '1';
                    v_guard := v_guard + 1;
                    assert v_guard < 20_000
                        report "GCM dir " & integer'image(dir)
                             & ": TIMEOUT on s_axis_tready" severity failure;
                end loop;
            end loop;
            aes_s_tvalid(dir) <= '0';
            aes_s_tlast(dir)  <= '0';
            aes_s_tkeep(dir)  <= (others => '0');
        end procedure;

        -- collect the recovered packet and compare it with the original
        procedure aes_recv_pkt (dir : integer; pkt : byte_arr_t;
                                label_str : string) is
            variable v_cnt   : integer := 0;
            variable v_bad   : integer := 0;
            variable v_byte  : std_logic_vector(7 downto 0);
            variable v_guard : integer := 0;
        begin
            aes_m_tready(dir) <= '1';
            loop
                wait until rising_edge(clk);
                if aes_m_tvalid(dir) = '1' then
                    for lane in 0 to c_AES_LANES - 1 loop
                        if aes_m_tkeep(dir)(lane) = '1' then
                            v_byte := aes_m_tdata(dir)(8 * lane + 7 downto 8 * lane);
                            if v_cnt < pkt'length and v_byte /= pkt(v_cnt) then
                                if v_bad < 8 then
                                    report label_str & ": round-trip mismatch at byte "
                                         & integer'image(v_cnt)
                                         & ": got " & to_hstring(v_byte)
                                         & " expected " & to_hstring(pkt(v_cnt))
                                        severity error;
                                end if;
                                v_bad := v_bad + 1;
                            end if;
                            v_cnt := v_cnt + 1;
                        end if;
                    end loop;
                    exit when aes_m_tlast(dir) = '1';
                end if;
                v_guard := v_guard + 1;
                assert v_guard < 20_000
                    report label_str & ": TIMEOUT waiting for the recovered packet"
                    severity failure;
            end loop;
            aes_m_tready(dir) <= '0';
            if v_cnt /= pkt'length then
                report label_str & ": recovered length " & integer'image(v_cnt)
                     & ", expected " & integer'image(pkt'length) severity error;
                v_errors := v_errors + 1;
            end if;
            if v_bad > 0 then
                report label_str & ": " & integer'image(v_bad) & " bad bytes"
                    severity error;
                v_errors := v_errors + v_bad;
            elsif v_cnt = pkt'length then
                report label_str & ": round-trip OK, all "
                     & integer'image(v_cnt) & " bytes recovered";
            end if;
        end procedure;

        variable v_qa_x, v_qa_y : std_logic_vector(c_EC_M - 1 downto 0);
        variable v_qb_x, v_qb_y : std_logic_vector(c_EC_M - 1 downto 0);
        variable v_z_a, v_z_b   : std_logic_vector(c_EC_M - 1 downto 0);
        variable v_key_a        : std_logic_vector(255 downto 0);
        variable v_key_b        : std_logic_vector(255 downto 0);
        variable v_guard        : integer;

    begin
        wait until rstn = '1';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- Step 1: private scalars arrive side-band, never through the stream
        ------------------------------------------------------------------------
        ecdh_k(0) <= C_SCALAR_A;
        ecdh_k(1) <= C_SCALAR_B;
        ecdh_k_valid <= (others => '1');
        wait until rising_edge(clk);
        ecdh_k_valid <= (others => '0');

        ------------------------------------------------------------------------
        -- Step 2: KEYGEN on both sides (they overlap; each core computes
        -- d * G while the testbench serves the other one)
        ------------------------------------------------------------------------
        report "STEP 1: ECDH KEYGEN on both sides (base point of B-571)";
        ecdh_send_pkt(0, '0', C_G_X, C_G_Y);
        ecdh_send_pkt(1, '0', C_G_X, C_G_Y);
        ecdh_recv_pub(0, v_qa_x, v_qa_y, "KEYGEN A");
        ecdh_recv_pub(1, v_qb_x, v_qb_y, "KEYGEN B");

        if v_qa_x /= C_QA_X or v_qa_y /= C_QA_Y then
            report "KEYGEN A: public key differs from the ec_ladder.py model"
                severity error;
            v_errors := v_errors + 1;
        else
            report "KEYGEN A: public key matches the golden model";
        end if;
        if v_qb_x /= C_QB_X or v_qb_y /= C_QB_Y then
            report "KEYGEN B: public key differs from the ec_ladder.py model"
                severity error;
            v_errors := v_errors + 1;
        else
            report "KEYGEN B: public key matches the golden model";
        end if;

        ------------------------------------------------------------------------
        -- Step 3: the testbench carries the public keys across (the only
        -- values that travel between the parties), then each side computes
        -- the shared secret. The KMAC frame head goes into each SHA-3 core
        -- up front, so the message is already waiting for Z.
        ------------------------------------------------------------------------
        report "STEP 2: public key exchange + SHARED on both sides";
        ecdh_send_pkt(0, '1', v_qb_x, v_qb_y);   -- A receives Q_B as sent by B
        ecdh_send_pkt(1, '1', v_qa_x, v_qa_y);   -- B receives Q_A as sent by A

        for w in 0 to c_HEAD_WORDS - 1 loop
            sha3_send_word(0, head_word(w), (others => '1'), '0');
        end loop;
        for w in 0 to c_HEAD_WORDS - 1 loop
            sha3_send_word(1, head_word(w), (others => '1'), '0');
        end loop;

        report "STEP 3: Z relayed word-for-word into the KMAC frame";
        relay_z(0, v_z_a, "SHARED A");
        send_tail(0);
        relay_z(1, v_z_b, "SHARED B");
        send_tail(1);

        if v_z_a /= C_Z then
            report "SHARED A: Z differs from the ec_ladder.py model" severity error;
            v_errors := v_errors + 1;
        end if;
        if v_z_b /= C_Z then
            report "SHARED B: Z differs from the ec_ladder.py model" severity error;
            v_errors := v_errors + 1;
        end if;
        if v_z_a = v_z_b then
            report "SHARED: both sides computed the same Z";
        else
            report "SHARED: the two sides disagree on Z" severity error;
            v_errors := v_errors + 1;
        end if;

        ------------------------------------------------------------------------
        -- Step 4: both SHA-3 cores squeeze the 256-bit session key
        ------------------------------------------------------------------------
        report "STEP 4: KMAC256 as KDF derives the session key on both sides";
        sha3_recv_key(0, v_key_a, "KDF A");
        sha3_recv_key(1, v_key_b, "KDF B");

        if v_key_a /= C_SESSION_KEY then
            report "KDF A: session key differs from the Python reference"
                severity error;
            v_errors := v_errors + 1;
        else
            report "KDF A: session key matches the Python reference";
        end if;
        if v_key_b /= C_SESSION_KEY then
            report "KDF B: session key differs from the Python reference"
                severity error;
            v_errors := v_errors + 1;
        else
            report "KDF B: session key matches the Python reference";
        end if;
        if v_key_a /= v_key_b then
            report "KDF: the two sides disagree on K" severity error;
            v_errors := v_errors + 1;
        end if;

        ------------------------------------------------------------------------
        -- Step 5: the derived keys go straight to the GCM key ports; each
        -- direction is encrypted with one side's key and decrypted with the
        -- other side's
        ------------------------------------------------------------------------
        report "STEP 5: session keys loaded into the AES-GCM chains";
        aes_key_a <= v_key_a;
        aes_key_b <= v_key_b;
        wait until rising_edge(clk);
        aes_cfg_valid <= '1';
        wait until rising_edge(clk);
        aes_cfg_valid <= '0';

        -- let the AES cores expand the key and derive H and E_k(J0)
        for i in 0 to 299 loop
            wait until rising_edge(clk);
        end loop;

        report "STEP 6: A -> B packet (encrypt with K_A, decrypt with K_B)";
        aes_send_pkt(0, C_PKT_AB);
        aes_recv_pkt(0, C_PKT_AB, "PACKET A->B");

        v_guard := 0;
        while mon_done(0) /= '1' loop
            wait until rising_edge(clk);
            v_guard := v_guard + 1;
            assert v_guard < 1000
                report "A->B wire monitor never finished" severity failure;
        end loop;
        wait until rising_edge(clk);
        if auth_seen(0) = '1' then
            report "PACKET A->B: tag verified by side B";
        else
            report "PACKET A->B: o_auth_ok never asserted" severity error;
            v_errors := v_errors + 1;
        end if;

        report "STEP 7: B -> A packet (encrypt with K_B, decrypt with K_A)";
        aes_send_pkt(1, C_PKT_BA);
        aes_recv_pkt(1, C_PKT_BA, "PACKET B->A");

        v_guard := 0;
        while mon_done(1) /= '1' loop
            wait until rising_edge(clk);
            v_guard := v_guard + 1;
            assert v_guard < 1000
                report "B->A wire monitor never finished" severity failure;
        end loop;
        wait until rising_edge(clk);
        if auth_seen(1) = '1' then
            report "PACKET B->A: tag verified by side A";
        else
            report "PACKET B->A: o_auth_ok never asserted" severity error;
            v_errors := v_errors + 1;
        end if;

        ------------------------------------------------------------------------
        -- Verdict
        ------------------------------------------------------------------------
        v_errors := v_errors + mon_errors(0) + mon_errors(1);
        report "TOTAL CYCLES: " & integer'image(r_cycles);
        if v_errors = 0 then
            report "ALL TESTS PASSED";
            report "RESULT: PASS";
        else
            report "RESULT: FAIL (" & integer'image(v_errors) & " errors)"
                severity error;
        end if;

        done <= true;
        wait for 100 ns;
        finish;
    end process;

    p_WATCHDOG : process
    begin
        wait for 4 ms;
        report "RESULT: FAIL (timeout - possible deadlock)" severity error;
        finish;
    end process;

end architecture;
