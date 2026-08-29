----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : June 2026
-- Design Name   : gcm_enc_glue
-- Module Name   : gcm_enc_glue - rtl
-- Project Name  : AES-128/256 + GCM (master thesis)
-- Tool Version  : Vivado 2025.1
--
-- Description   : GCM encryptor static glue (the static half of the
--                 static/dynamic split). Wires together axis_demux,
--                 axis_broadcaster (AAD + CT splits),
--                 axis_ghash_mux, GHASH_wrapper, Tag_Finalizer and axis_mux;
--                 the crypto algorithm itself lives OUTSIDE, behind the
--                 crypto-boundary ports (PT stream out, CT stream in,
--                 key/IV pass-through, H / E_K(J0) / in-proc side-band in).
--                 The boundary matches AES_algorithm. AXIS slave carries
--                 AAD || PT (TLAST on last PT beat); AXIS master emits
--                 AAD || CT || ICV (TLAST on ICV beat).
--
-- Dependencies  : work.GHASH_wrapper, work.Tag_Finalizer, work.axis_demux,
--                 work.axis_mux, work.axis_ghash_mux,
--                 work.axis_broadcaster, work.AXIS_skid_buffer
--
-- Revision      :
--   0.01 - May 2026 - File Created
--   0.02 - July 2026 - AAD_BYTES generic added and passed to axis_demux, which
--          now derives the AAD bit length from it instead of AAD_BEATS *
--          DATA_WIDTH, since the AAD length need not be a multiple of the bus
--          width.
--   0.03 - July 2026 - The AXIS beats are byte/bit reversed at the slave and the
--          master port so the core works in GCM block order. AXIS carries byte 0
--          in the LSB lane while AES and GHASH place byte 0 at the MSB of a
--          block, so without the reversal the keystream and the GHASH blocks
--          were applied byte-mirrored: the stack round-tripped with itself but
--          did not match the GCM standard. Verified against NIST SP 800-38D
--          test case 4.
--
-- Additional Comments :
--   Active-low reset (i_rstn) throughout. Single clock domain (i_clk).
--
--   GHASH throughput: the pipelined GHASH_wrapper ingests one 128-bit beat
--   every 2 clocks (Karatsuba-32 layer is registered; an internal r_pipe_busy
--   throttle gates s_axis_tready every other cycle). This caps the steady-
--   state throughput of the GCM stack at 0.5 blocks / cycle regardless of
--   how many crypto cores are instantiated -- additional cores beyond what
--   the AAD || CT path can feed at one beat per two cycles add latency hiding
--   but no extra bandwidth.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gcm_enc_glue is
    generic (
        AAD_BEATS    : natural  := 2;         -- 0 = no AAD path
        AAD_BYTES    : natural  := 20;        -- AAD length in bytes
        DATA_WIDTH   : positive := 128;
        MULT_CYCLES  : integer  := 2          -- GHASH multiply timing: 1 or 2 clock cycles
    );
    port (
        i_clk         : in  std_logic;
        i_rstn        : in  std_logic;

        -- Telemetry tick: resets/gates the output-handshake counter
        i_tick        : in  std_logic := '0';

        -- Key + nonce config. i_key is the 256-bit caller-side key; the
        -- AES core uses only the LSB AES_BITS bits. i_nonce is the 96-bit
        -- GCM nonce; the algorithm module forms J0 = nonce || 0^31 || 1.
        i_key         : in  std_logic_vector(255 downto 0);
        i_key_valid   : in  std_logic;
        i_nonce       : in  std_logic_vector(95 downto 0);
        i_nonce_valid : in  std_logic;

        -- AXIS slave: AAD || PT (TLAST on last PT beat)
        s_axis_tdata  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_axis_tkeep  : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXIS master: AAD || CT || ICV (TLAST on ICV beat)
        m_axis_tdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_axis_tkeep  : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tready : in  std_logic;

        -- Side-band: in-proc flag + output-handshake counter
        o_ENC_in_proc : out std_logic;
        o_TxENC       : out std_logic_vector(31 downto 0);  -- 32-bit counter

        -- Crypto boundary: key + nonce pass-through toward the algorithm module
        o_crypto_key       : out std_logic_vector(255 downto 0);
        o_crypto_key_valid : out std_logic;
        o_crypto_nonce     : out std_logic_vector(95 downto 0);
        o_crypto_nonce_valid  : out std_logic;

        -- Crypto boundary: PT stream toward the algorithm module
        m_pt_axis_tdata    : out std_logic_vector(DATA_WIDTH-1 downto 0);
        m_pt_axis_tkeep    : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
        m_pt_axis_tvalid   : out std_logic;
        m_pt_axis_tlast    : out std_logic;
        m_pt_axis_tready   : in  std_logic;

        -- Crypto boundary: CT stream back from the algorithm module
        s_ct_axis_tdata    : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        s_ct_axis_tkeep    : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
        s_ct_axis_tvalid   : in  std_logic;
        s_ct_axis_tlast    : in  std_logic;
        s_ct_axis_tready   : out std_logic;

        -- Crypto boundary: side-band from the algorithm module
        i_crypto_H         : in  std_logic_vector(127 downto 0);
        i_crypto_H_valid   : in  std_logic;
        i_crypto_E_k       : in  std_logic_vector(127 downto 0);
        i_crypto_E_k_valid : in  std_logic;
        i_crypto_h_stale   : in  std_logic;                     -- '1' while crypto H is not yet valid
        i_crypto_in_proc   : in  std_logic
    );
end entity;

architecture rtl of gcm_enc_glue is

    constant c_TKEEP_W : positive := DATA_WIDTH/8;

    ----------------------------------------------------------------------------
    -- Byte order at the AXIS boundary.
    -- AXIS carries byte 0 of the stream in the LSB lane (TDATA[7:0]), while AES
    -- and GHASH take byte 0 of a 128-bit block at the MSB. The stream is
    -- therefore reversed once on the way in and once on the way out; everything
    -- in between works in block order. TDATA is reversed by byte and TKEEP by
    -- bit, which preserves the "keep bit i marks byte i" relation that every
    -- internal module relies on. A partial beat then lands its valid bytes at
    -- the top of the block, which is exactly the GCM zero-padding rule.
    ----------------------------------------------------------------------------
    function byte_reverse (constant v : std_logic_vector) return std_logic_vector is
        constant c_N   : natural := v'length / 8;
        variable v_out : std_logic_vector(v'length-1 downto 0);
    begin
        for i in 0 to c_N-1 loop
            v_out(8*i+7 downto 8*i) := v(8*(c_N-1-i)+7 downto 8*(c_N-1-i));
        end loop;
        return v_out;
    end function;

    function bit_reverse (constant v : std_logic_vector) return std_logic_vector is
        constant c_N   : natural := v'length;
        variable v_out : std_logic_vector(c_N-1 downto 0);
    begin
        for i in 0 to c_N-1 loop
            v_out(i) := v(c_N-1-i);
        end loop;
        return v_out;
    end function;

    ----------------------------------------------------------------------------
    -- Side-band: in-proc flag + output-handshake counter
    ----------------------------------------------------------------------------
    signal w_enc_in_proc      : std_logic;                      -- from wrapper
    signal w_m_axis_tvalid    : std_logic;                      -- internal copy of m_axis_tvalid
    signal w_m_axis_tlast     : std_logic;                      -- internal copy of m_axis_tlast
    signal w_output_handshake : std_logic;                      -- m_axis beat with tlast
    signal r_TxENC            : unsigned(31 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- axis_demux outputs: AAD split + PT split + length counters for GHASH
    ----------------------------------------------------------------------------
    signal w_aad_tdata     : std_logic_vector(DATA_WIDTH-1 downto 0);  -- AAD beat data
    signal w_aad_tkeep     : std_logic_vector(c_TKEEP_W-1 downto 0);   -- AAD beat byte mask
    signal w_aad_tvalid    : std_logic;                                -- AAD beat valid
    signal w_aad_tready    : std_logic;                                -- AAD beat ready (driven by AAD broadcaster)

    signal w_pt_tdata      : std_logic_vector(DATA_WIDTH-1 downto 0);  -- PT beat data into AES core
    signal w_pt_tkeep      : std_logic_vector(c_TKEEP_W-1 downto 0);   -- PT beat byte mask
    signal w_pt_tvalid     : std_logic;                                -- PT beat valid
    signal w_pt_tlast      : std_logic;                                -- TLAST on last PT beat (propagated from s_axis)
    signal w_pt_tready     : std_logic;                                -- PT beat ready (driven by AES core)

    signal w_aad_bit_len   : std_logic_vector(63 downto 0);            -- AAD length in bits (NIST GCM len block)
    signal w_ct_bit_len    : std_logic_vector(63 downto 0);            -- CT length in bits  (NIST GCM len block)
    signal w_len_valid     : std_logic;                                -- 1-cycle pulse: lengths sampled at end-of-packet

    ----------------------------------------------------------------------------
    -- AAD broadcaster (1 -> 2): -> { axis_ghash_mux.s_aad, axis_mux.s_aad }
    ----------------------------------------------------------------------------
    signal w_aad_bc_tdata  : std_logic_vector(2*DATA_WIDTH-1 downto 0);  -- packed: high half = mux copy, low half = ghmux copy
    signal w_aad_bc_tkeep  : std_logic_vector(2*c_TKEEP_W-1 downto 0);   -- packed byte masks (same layout)
    signal w_aad_bc_tlast  : std_logic_vector(1 downto 0);               -- per-copy TLAST (forced low here — AAD has no TLAST)
    signal w_aad_bc_tvalid : std_logic_vector(1 downto 0);               -- per-copy valid
    signal w_aad_bc_tready : std_logic_vector(1 downto 0);               -- per-copy ready

    ----------------------------------------------------------------------------
    -- AES core outputs: CT keystream stream + side-band H, E_K(J0)
    ----------------------------------------------------------------------------
    signal w_ct_tdata      : std_logic_vector(DATA_WIDTH-1 downto 0);  -- CT beat data
    signal w_ct_tkeep      : std_logic_vector(c_TKEEP_W-1 downto 0);   -- CT beat byte mask
    signal w_ct_tvalid     : std_logic;                                -- CT beat valid
    signal w_ct_tlast      : std_logic;                                -- TLAST on last CT beat
    signal w_ct_tready     : std_logic;                                -- CT beat ready (driven by CT broadcaster)

    signal w_H             : std_logic_vector(127 downto 0);  -- AES_K(0)  — hash key into GHASH
    signal w_H_valid       : std_logic;                       -- 1-cycle pulse when H is captured
    signal w_EJ0           : std_logic_vector(127 downto 0);  -- AES_K(J0) — tag mask into Tag_Finalizer
    signal w_EJ0_valid     : std_logic;                       -- 1-cycle pulse when EJ0 is captured

    ----------------------------------------------------------------------------
    -- CT broadcaster (1 -> 2): -> { axis_ghash_mux.s_ct, axis_mux.s_ct }
    ----------------------------------------------------------------------------
    signal w_ct_bc_tdata   : std_logic_vector(2*DATA_WIDTH-1 downto 0);  -- packed CT copies
    signal w_ct_bc_tkeep   : std_logic_vector(2*c_TKEEP_W-1 downto 0);
    signal w_ct_bc_tlast   : std_logic_vector(1 downto 0);
    signal w_ct_bc_tvalid  : std_logic_vector(1 downto 0);
    signal w_ct_bc_tready  : std_logic_vector(1 downto 0);

    ----------------------------------------------------------------------------
    -- axis_ghash_mux output: merged AAD || CT stream into GHASH
    ----------------------------------------------------------------------------
    signal w_ghmux_tdata   : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_ghmux_tkeep   : std_logic_vector(c_TKEEP_W-1 downto 0);
    signal w_ghmux_tvalid  : std_logic;
    signal w_ghmux_tlast   : std_logic;
    signal w_ghmux_tready  : std_logic;

    ----------------------------------------------------------------------------
    -- H-freshness gate on the GHASH ingress (rationale at p_GH_GATE below)
    ----------------------------------------------------------------------------
    signal w_ghmux_tvalid_g : std_logic;         -- gated valid into the skid buffer
    signal w_gh_sb_tready   : std_logic;         -- skid buffer's raw ingress ready
    signal w_gh_gate_open   : std_logic;         -- pass condition
    signal w_h_stale        : std_logic;         -- crypto core: latched H not yet valid
    signal r_gh_in_pkt      : std_logic := '0';  -- absorb packet in flight

    ----------------------------------------------------------------------------
    -- AXIS skid buffer output: registered AAD || CT stream feeding GHASH.
    -- +1 cycle of GHASH ingress latency, 1 beat/cycle steady-state throughput.
    ----------------------------------------------------------------------------
    signal w_sb_tdata      : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_sb_tvalid     : std_logic;
    signal w_sb_tlast      : std_logic;
    signal w_sb_tready     : std_logic;

    ----------------------------------------------------------------------------
    -- GHASH_wrapper output: GHASH(H, AAD || CT, lengths) -> Y
    ----------------------------------------------------------------------------
    signal w_Y             : std_logic_vector(127 downto 0);
    signal w_Y_valid       : std_logic;

    ----------------------------------------------------------------------------
    -- Tag_Finalizer output: ICV = Y XOR E_K(J0) as a single AXIS beat
    ----------------------------------------------------------------------------
    signal w_icv_tdata     : std_logic_vector(127 downto 0);
    signal w_icv_tvalid    : std_logic;
    signal w_icv_tlast     : std_logic;
    signal w_icv_tready    : std_logic;
    signal w_icv_tkeep     : std_logic_vector(c_TKEEP_W-1 downto 0);  -- forced to all-ones (Tag_Finalizer has no TKEEP port)

    ----------------------------------------------------------------------------
    -- Block-order copies of the AXIS slave / master beats
    ----------------------------------------------------------------------------
    signal w_s_tdata_blk : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_s_tkeep_blk : std_logic_vector(c_TKEEP_W-1 downto 0);
    signal w_m_tdata_blk : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal w_m_tkeep_blk : std_logic_vector(c_TKEEP_W-1 downto 0);

begin

    w_s_tdata_blk <= byte_reverse(s_axis_tdata);
    w_s_tkeep_blk <= bit_reverse (s_axis_tkeep);
    m_axis_tdata  <= byte_reverse(w_m_tdata_blk);
    m_axis_tkeep  <= bit_reverse (w_m_tkeep_blk);

    --------------------------------------------------------------------------
    -- axis_demux: split s_axis into AAD and PT, emit length counters
    --------------------------------------------------------------------------
    u_demux : entity work.axis_demux
        generic map (
            AAD_BEATS  => AAD_BEATS,
            AAD_BYTES  => AAD_BYTES,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,

            s_axis_tdata  => w_s_tdata_blk,
            s_axis_tkeep  => w_s_tkeep_blk,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tready => s_axis_tready,

            m_aad_tdata   => w_aad_tdata,
            m_aad_tkeep   => w_aad_tkeep,
            m_aad_tvalid  => w_aad_tvalid,
            m_aad_tready  => w_aad_tready,

            m_pt_tdata    => w_pt_tdata,
            m_pt_tkeep    => w_pt_tkeep,
            m_pt_tvalid   => w_pt_tvalid,
            m_pt_tlast    => w_pt_tlast,
            m_pt_tready   => w_pt_tready,

            o_aad_bit_len => w_aad_bit_len,
            o_ct_bit_len  => w_ct_bit_len,
            o_len_valid   => w_len_valid
        );

    --------------------------------------------------------------------------
    -- AAD broadcaster: 1 -> 2 fan-out into axis_ghash_mux + axis_mux. No TLAST.
    --------------------------------------------------------------------------
    u_aad_bc : entity work.axis_broadcaster
        generic map (
            NUM_MASTERS => 2,
            DATA_WIDTH  => DATA_WIDTH,
            HAS_TKEEP   => true,
            HAS_TLAST   => false
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,
            s_axis_tdata  => w_aad_tdata,
            s_axis_tkeep  => w_aad_tkeep,
            s_axis_tlast  => '0',
            s_axis_tvalid => w_aad_tvalid,
            s_axis_tready => w_aad_tready,
            m_axis_tdata  => w_aad_bc_tdata,
            m_axis_tkeep  => w_aad_bc_tkeep,
            m_axis_tlast  => w_aad_bc_tlast,
            m_axis_tvalid => w_aad_bc_tvalid,
            m_axis_tready => w_aad_bc_tready
        );

    --------------------------------------------------------------------------
    -- Crypto boundary wiring. The algorithm module (AES_algorithm)
    -- sits outside this entity: PT goes out,
    -- CT comes back, key/IV pass through, H / E_K(J0) / in-proc come in.
    --------------------------------------------------------------------------
    o_crypto_key       <= i_key;
    o_crypto_key_valid <= i_key_valid;
    o_crypto_nonce        <= i_nonce;
    o_crypto_nonce_valid  <= i_nonce_valid;

    m_pt_axis_tdata  <= w_pt_tdata;
    m_pt_axis_tkeep  <= w_pt_tkeep;
    m_pt_axis_tvalid <= w_pt_tvalid;
    m_pt_axis_tlast  <= w_pt_tlast;
    w_pt_tready      <= m_pt_axis_tready;

    w_ct_tdata       <= s_ct_axis_tdata;
    w_ct_tkeep       <= s_ct_axis_tkeep;
    w_ct_tvalid      <= s_ct_axis_tvalid;
    w_ct_tlast       <= s_ct_axis_tlast;
    s_ct_axis_tready <= w_ct_tready;

    w_H           <= i_crypto_H;
    w_H_valid     <= i_crypto_H_valid;
    w_EJ0         <= i_crypto_E_k;
    w_EJ0_valid   <= i_crypto_E_k_valid;
    w_h_stale     <= i_crypto_h_stale;
    w_enc_in_proc <= i_crypto_in_proc;

    --------------------------------------------------------------------------
    -- CT broadcaster: 1 -> 2 fan-out into axis_ghash_mux + axis_mux. TLAST propagated.
    --------------------------------------------------------------------------
    u_ct_bc : entity work.axis_broadcaster
        generic map (
            NUM_MASTERS => 2,
            DATA_WIDTH  => DATA_WIDTH,
            HAS_TKEEP   => true,
            HAS_TLAST   => true
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,
            s_axis_tdata  => w_ct_tdata,
            s_axis_tkeep  => w_ct_tkeep,
            s_axis_tlast  => w_ct_tlast,
            s_axis_tvalid => w_ct_tvalid,
            s_axis_tready => w_ct_tready,
            m_axis_tdata  => w_ct_bc_tdata,
            m_axis_tkeep  => w_ct_bc_tkeep,
            m_axis_tlast  => w_ct_bc_tlast,
            m_axis_tvalid => w_ct_bc_tvalid,
            m_axis_tready => w_ct_bc_tready
        );

    --------------------------------------------------------------------------
    -- axis_ghash_mux: { AAD bc[0], CT bc[0] } -> GHASH_wrapper
    --------------------------------------------------------------------------
    u_ghmux : entity work.axis_ghash_mux
        generic map (
            AAD_BEATS  => AAD_BEATS,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,

            s_aad_tdata   => w_aad_bc_tdata(DATA_WIDTH-1 downto 0),
            s_aad_tkeep   => w_aad_bc_tkeep(c_TKEEP_W-1 downto 0),
            s_aad_tvalid  => w_aad_bc_tvalid(0),
            s_aad_tready  => w_aad_bc_tready(0),

            s_ct_tdata    => w_ct_bc_tdata(DATA_WIDTH-1 downto 0),
            s_ct_tkeep    => w_ct_bc_tkeep(c_TKEEP_W-1 downto 0),
            s_ct_tvalid   => w_ct_bc_tvalid(0),
            s_ct_tlast    => w_ct_bc_tlast(0),
            s_ct_tready   => w_ct_bc_tready(0),

            m_axis_tdata  => w_ghmux_tdata,
            m_axis_tkeep  => w_ghmux_tkeep,
            m_axis_tvalid => w_ghmux_tvalid,
            m_axis_tlast  => w_ghmux_tlast,
            m_axis_tready => w_ghmux_tready
        );

    --------------------------------------------------------------------------
    -- AXIS skid buffer between axis_ghash_mux and GHASH_wrapper. Registers
    -- TDATA/TVALID/TLAST and holds a 1-deep skid slot so no beat is lost
    -- when GHASH_wrapper de-asserts TREADY (S_WAIT_LEN / S_SEND_LEN /
    -- S_WAIT_Y states).
    --------------------------------------------------------------------------
    u_ghash_sb : entity work.AXIS_skid_buffer
        generic map (
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,

            s_axis_tdata  => w_ghmux_tdata,
            s_axis_tvalid => w_ghmux_tvalid_g,
            s_axis_tlast  => w_ghmux_tlast,
            s_axis_tready => w_gh_sb_tready,

            m_axis_tdata  => w_sb_tdata,
            m_axis_tvalid => w_sb_tvalid,
            m_axis_tlast  => w_sb_tlast,
            m_axis_tready => w_sb_tready
        );

    --------------------------------------------------------------------------
    -- H-freshness gate. GHASH_wrapper latches H on the o_H_valid pulse, but
    -- the absorb stream is not data-dependent on H (AAD beats never touch
    -- the AES keystream), so under dense streaming the first beats of a
    -- packet can reach GHASH before the H of that packet's key is computed.
    -- The crypto core reports H validity directly via i_crypto_h_stale: high
    -- while a key change is still awaiting its recompute, low once H is fresh.
    -- A key the core defers to the next packet boundary keeps H valid for the
    -- in-flight packet, so that packet is never held; only a packet whose own
    -- H is stale waits. A packet already absorbing is never stalled (its H is
    -- final and it must drain), tracked by r_gh_in_pkt.
    --------------------------------------------------------------------------
    w_gh_gate_open   <= r_gh_in_pkt or (not w_h_stale);
    w_ghmux_tvalid_g <= w_ghmux_tvalid and w_gh_gate_open;
    w_ghmux_tready   <= w_gh_sb_tready and w_gh_gate_open;

    p_GH_GATE : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_gh_in_pkt <= '0';
            else
                -- absorb-packet tracking on the gated handshake
                if w_ghmux_tvalid_g = '1' and w_gh_sb_tready = '1' then
                    if w_ghmux_tlast = '1' then
                        r_gh_in_pkt <= '0';
                    else
                        r_gh_in_pkt <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------------
    -- GHASH_wrapper: streamed AAD||CT + lengths + H -> Y
    --------------------------------------------------------------------------
    u_ghash : entity work.GHASH_wrapper
        generic map (
            MULT_CYCLES => MULT_CYCLES
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,

            s_axis_tdata  => w_sb_tdata,
            s_axis_tvalid => w_sb_tvalid,
            s_axis_tlast  => w_sb_tlast,
            s_axis_tready => w_sb_tready,

            i_H           => w_H,
            i_H_valid     => w_H_valid,

            i_aad_bit_len => w_aad_bit_len,
            i_ct_bit_len  => w_ct_bit_len,
            i_len_valid   => w_len_valid,

            o_Y           => w_Y,
            o_Y_valid     => w_Y_valid
        );

    --------------------------------------------------------------------------
    -- Tag_Finalizer: Y XOR E_K(J0) -> ICV (single-beat AXIS master)
    --------------------------------------------------------------------------
    u_tag : entity work.Tag_Finalizer
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,

            i_EJ0         => w_EJ0,
            i_EJ0_valid   => w_EJ0_valid,

            i_Y           => w_Y,
            i_Y_valid     => w_Y_valid,

            m_axis_tdata  => w_icv_tdata,
            m_axis_tvalid => w_icv_tvalid,
            m_axis_tlast  => w_icv_tlast,
            m_axis_tready => w_icv_tready
        );

    -- Tag_Finalizer's m_axis has no TKEEP port; force all-bytes-valid.
    w_icv_tkeep <= (others => '1');

    --------------------------------------------------------------------------
    -- axis_mux: { AAD bc[1], CT bc[1], ICV } -> top m_axis
    --------------------------------------------------------------------------
    u_mux : entity work.axis_mux
        generic map (
            AAD_BEATS  => AAD_BEATS,
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            i_clk         => i_clk,
            i_rstn        => i_rstn,

            s_aad_tdata   => w_aad_bc_tdata(2*DATA_WIDTH-1 downto DATA_WIDTH),
            s_aad_tkeep   => w_aad_bc_tkeep(2*c_TKEEP_W-1 downto c_TKEEP_W),
            s_aad_tvalid  => w_aad_bc_tvalid(1),
            s_aad_tready  => w_aad_bc_tready(1),

            s_ct_tdata    => w_ct_bc_tdata(2*DATA_WIDTH-1 downto DATA_WIDTH),
            s_ct_tkeep    => w_ct_bc_tkeep(2*c_TKEEP_W-1 downto c_TKEEP_W),
            s_ct_tvalid   => w_ct_bc_tvalid(1),
            s_ct_tlast    => w_ct_bc_tlast(1),
            s_ct_tready   => w_ct_bc_tready(1),

            s_icv_tdata   => w_icv_tdata,
            s_icv_tkeep   => w_icv_tkeep,
            s_icv_tvalid  => w_icv_tvalid,
            s_icv_tready  => w_icv_tready,

            m_axis_tdata  => w_m_tdata_blk,
            m_axis_tkeep  => w_m_tkeep_blk,
            m_axis_tvalid => w_m_axis_tvalid,
            m_axis_tlast  => w_m_axis_tlast,
            m_axis_tready => m_axis_tready
        );

    m_axis_tvalid <= w_m_axis_tvalid;
    m_axis_tlast  <= w_m_axis_tlast;

    --------------------------------------------------------------------------
    -- Side-band: in-proc flag straight from the wrapper
    --------------------------------------------------------------------------
    o_ENC_in_proc <= w_enc_in_proc;

    --------------------------------------------------------------------------
    -- Output-handshake counter. i_tick resets it (to 1 if a beat coincides,
    -- else 0); otherwise it increments only on the last beat (tlast) of an
    -- m_axis handshake -- i.e. one count per emitted packet.
    --------------------------------------------------------------------------
    w_output_handshake <= w_m_axis_tvalid and m_axis_tready and w_m_axis_tlast;

    p_CRYPTO_COUNTER_PROCESS : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_TxENC <= (others => '0');
            elsif i_tick = '1' then
                if w_output_handshake = '1' then
                    r_TxENC <= to_unsigned(1, r_TxENC'length);
                else
                    r_TxENC <= (others => '0');
                end if;
            elsif w_output_handshake = '1' then
                r_TxENC <= r_TxENC + 1;
            end if;
        end if;
    end process p_CRYPTO_COUNTER_PROCESS;

    o_TxENC <= std_logic_vector(r_TxENC);

end architecture;
