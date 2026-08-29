----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : May 2026
-- Design Name   : key_expansion
-- Module Name   : key_expansion - rtl
-- Tool Version  : Vivado 2025.1
--
-- Description   : Iterative AES key expansion, 4 words per clock cycle.
--                 Supports AES-128 (Nk=4) and AES-256 (Nk=8); rejects AES-192.
--                 Outputs round keys via arr_round_keys_t with per-cycle
--                 availability so downstream cores can dispatch in lockstep
--                 (no global "all keys ready" handshake). Alongside the
--                 array, a write stream (o_rk_wr_*) presents each derived
--                 round key K_1..K_NR combinationally on the cycle its r_rk
--                 registers are written, so a consumer keeping a local
--                 distributed-RAM copy loads it on the same clock edge and
--                 sees exactly the register-array read timing.
--
-- Dependencies  : work.aes_pkg
--
-- Revision      :
--   0.01 - May 2026 - File Created
--   0.02 - Aug 2026 - Four-word bundle lifted into combinational signals;
--                     added the o_rk_wr_* round-key write stream for
--                     per-core distributed-RAM copies (array output and
--                     its timing unchanged)
--
-- Additional Comments :
--   Active-low reset (i_rstn). AES-192 (Nk=6) rejected at elaboration via
--   assert. 
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.aes_pkg.all;

entity KeyExpansion is
    generic (
        KEY_BITS : integer := 128       -- 128 or 256
    );
    port (
        i_clk        : in  std_logic;
        i_rstn       : in  std_logic;   -- active low
        i_new_key    : in  std_logic;
        i_key        : in  std_logic_vector(255 downto 0);
        -- o_round_keys(0) = K0 (initial AddRoundKey, = i_key(255 downto 128))
        -- o_round_keys(1..c_NR) = derived round keys
        -- o_round_keys(c_NR+1..14) = 0 (only for AES-128)
        o_round_keys : out arr_round_keys_t;

        -- Round-key write stream for per-core distributed-RAM copies. Carries
        -- K_1..K_NR (K_0 is exported through o_round_keys(0), a constant
        -- index). Combinational: each key is valid on the cycle its r_rk
        -- registers are written, so a RAM copy that registers this stream
        -- loads on the same clock edge and its read timing matches the array.
        o_rk_wr_en   : out std_logic;
        o_rk_wr_addr : out unsigned(3 downto 0);
        o_rk_wr_data : out std_logic_vector(127 downto 0)
    );
end entity;

architecture rtl of KeyExpansion is

    constant c_NK          : integer := KEY_BITS / 32;    -- 4 or 8
    constant c_NR          : integer := c_NK + 6;
    constant c_TOTAL_WORDS : integer := 4 * (c_NR + 1);   -- 44 or 60

    type arr_word_t is array (natural range <>) of std_logic_vector(31 downto 0);

    -- FSM
    type state_t is (S_IDLE, S_EXPANDING, S_DONE);
    signal state_reg  : state_t := S_IDLE;
    signal next_state : state_t;

    -- Shift register window: r_window(Nk-1) = W[i-1], r_window(0) = W[i-Nk]
    signal r_window : arr_word_t(0 to c_NK-1) := (others => (others => '0'));

    -- Output round key words W[4..59], written once each via clock-enable
    signal r_rk : arr_word_t(4 to 59) := (others => (others => '0'));

    -- K0 (initial AddRoundKey) = top 128 bits of i_key, latched on LOAD
    signal r_k0 : std_logic_vector(127 downto 0) := (others => '0');

    -- Walking-4 write strobe: four consecutive '1's, shifts up by 4 per cycle
    signal r_we : std_logic_vector(4 to 59) := (others => '0');

    -- Position within Nk-group: 0 = twist, 4 = AES-256 mid-group extra SubWord
    signal r_modcnt : integer range 0 to 7  := 0;
    signal r_rcon   : integer range 1 to 10 := 1;

    signal w_is_last : std_logic;

    -- Four-word bundle of the current EXPANDING cycle, combinational so the
    -- same values drive both the r_rk register file and the o_rk_wr_* stream
    -- on the same clock edge. Pure code motion out of p_DATAPATH: the
    -- expressions are unchanged, so no logic is duplicated.
    signal w_prev : std_logic_vector(31 downto 0);
    signal w_temp : std_logic_vector(31 downto 0);
    signal w_w0, w_w1, w_w2, w_w3 : std_logic_vector(31 downto 0);

    -- Round index the current EXPANDING cycle is producing (drives
    -- o_rk_wr_addr): set at LOAD to the first derived key's index
    -- (2 for AES-256, whose K_1 comes straight from the key at LOAD;
    -- 1 for AES-128), then +1 per compute cycle.
    signal r_out_addr : integer range 0 to 15 := 0;

    -- LOAD fires this cycle (new key accepted in S_IDLE / S_DONE)
    signal w_load_fire : std_logic;

    -- Local SBox with rom_style="distributed" forces LUT mapping (Synth 8-5733
    -- workaround: Vivado ignores the attribute on the package constant c_SBOX,
    -- so it must live on an architecture-level signal).
    signal w_lcl_sbox : sbox_array_t := c_SBOX;
    attribute rom_style : string;
    attribute rom_style of w_lcl_sbox : signal is "distributed";

    -- Local sub_word indexed through the local SBox signal, so all four
    -- byte lookups map to distributed RAM instead of being inferred into BRAM.
    -- impure: it reads the w_lcl_sbox signal (a pure function may not).
    impure function sub_word_lcl(w : std_logic_vector(31 downto 0))
        return std_logic_vector
    is
        variable v_r : std_logic_vector(31 downto 0);
    begin
        v_r(31 downto 24) := w_lcl_sbox(to_integer(unsigned(w(31 downto 24))));
        v_r(23 downto 16) := w_lcl_sbox(to_integer(unsigned(w(23 downto 16))));
        v_r(15 downto 8)  := w_lcl_sbox(to_integer(unsigned(w(15 downto 8))));
        v_r(7  downto 0)  := w_lcl_sbox(to_integer(unsigned(w(7  downto 0))));
        return v_r;
    end function;

begin

    -- AES-192 (Nk=6) is not supported: 4 does not divide 6.
    assert (KEY_BITS = 128) or (KEY_BITS = 256)
        report "KeyExpansion: only KEY_BITS=128 or KEY_BITS=256 are supported"
        severity failure;

    ---------------------------------------------------------------------------
    -- FSM state register (active-low reset)
    ---------------------------------------------------------------------------
    p_STATE_REG : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                state_reg <= S_IDLE;
            else
                state_reg <= next_state;
            end if;
        end if;
    end process p_STATE_REG;

    ---------------------------------------------------------------------------
    -- Next-state logic (combinational)
    ---------------------------------------------------------------------------
    p_NEXT_STATE : process(state_reg, i_new_key, w_is_last)
    begin
        next_state <= state_reg;
        case state_reg is
            when S_IDLE =>
                if i_new_key = '1' then
                    next_state <= S_EXPANDING;
                end if;
            when S_EXPANDING =>
                if w_is_last = '1' then
                    next_state <= S_DONE;
                end if;
            when S_DONE =>
                if i_new_key = '1' then
                    next_state <= S_EXPANDING;
                end if;
        end case;
    end process p_NEXT_STATE;

    -- Last cycle: walking-4 strobe has reached the final r_rk slot
    w_is_last <= '1' when r_we(c_TOTAL_WORDS-1) = '1' else '0';

    ---------------------------------------------------------------------------
    -- Four-word bundle (combinational)
    --   w_temp = f(W[i-1])   where f is twist / extra-SubWord / id
    --   W[i+k] = r_window(k) XOR (k=0 ? w_temp : W[i+k-1])
    ---------------------------------------------------------------------------
    w_prev <= r_window(c_NK-1);

    p_TEMP : process(w_prev, r_modcnt, r_rcon)
        variable v_t : std_logic_vector(31 downto 0);
    begin
        if r_modcnt = 0 then
            -- Twist: RotWord -> SubWord -> XOR Rcon
            v_t := sub_word_lcl(rotr_word(w_prev, 3));
            v_t(31 downto 24) := v_t(31 downto 24) xor c_RCON(r_rcon);
        elsif (c_NK > 6) and (r_modcnt = 4) then
            -- AES-256 mid-group extra SubWord
            v_t := sub_word_lcl(w_prev);
        else
            -- Unreachable for Nk in {4,8} with 4-words-per-clock
            v_t := w_prev;
        end if;
        w_temp <= v_t;
    end process;

    w_w0 <= r_window(0) xor w_temp;
    w_w1 <= r_window(1) xor w_w0;
    w_w2 <= r_window(2) xor w_w1;
    w_w3 <= r_window(3) xor w_w2;

    ---------------------------------------------------------------------------
    -- Round-key write stream. On the LOAD cycle AES-256 already has K_1
    -- (= i_key low half); every EXPANDING cycle then emits one derived key.
    -- The stream is combinational, aligned with the edge that writes r_rk,
    -- so a distributed-RAM copy registers K_j on exactly the same edge as
    -- the r_rk registers themselves.
    ---------------------------------------------------------------------------
    w_load_fire <= '1' when (state_reg = S_IDLE or state_reg = S_DONE)
                        and i_new_key = '1'
                   else '0';

    o_rk_wr_en   <= '1' when (w_load_fire = '1' and c_NK = 8)
                          or (state_reg = S_EXPANDING)
                    else '0';
    o_rk_wr_addr <= to_unsigned(1, 4) when w_load_fire = '1'
                    else to_unsigned(r_out_addr, 4);
    o_rk_wr_data <= i_key(127 downto 0) when w_load_fire = '1'
                    else (w_w0 & w_w1 & w_w2 & w_w3);

    ---------------------------------------------------------------------------
    -- Datapath: load on new_key, otherwise compute 4 words per clock
    ---------------------------------------------------------------------------
    p_DATAPATH : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rstn = '0' then
                r_window   <= (others => (others => '0'));
                r_rk       <= (others => (others => '0'));
                r_k0       <= (others => '0');
                r_we       <= (others => '0');
                r_modcnt   <= 0;
                r_rcon     <= 1;
                r_out_addr <= 0;

            elsif (state_reg = S_IDLE or state_reg = S_DONE)
                  and i_new_key = '1' then
                ---------------------------------------------------------------
                -- LOAD: window <- first Nk key words; rk <- 0 except W[4..Nk-1]
                -- which are already round-key bits for AES-256.
                -- K0 = top 128 bits of i_key (same for AES-128 and AES-256).
                ---------------------------------------------------------------
                r_k0 <= i_key(255 downto 128);
                for k in 0 to c_NK-1 loop
                    r_window(k) <= i_key(255 - k*32 downto 224 - k*32);
                end loop;
                for j in 4 to 59 loop
                    if j <= c_NK-1 then
                        r_rk(j) <= i_key(255 - j*32 downto 224 - j*32);
                    else
                        r_rk(j) <= (others => '0');
                    end if;
                end loop;
                -- First four computed words land at positions Nk..Nk+3
                r_we       <= (others => '0');
                r_we(c_NK)   <= '1';
                r_we(c_NK+1) <= '1';
                r_we(c_NK+2) <= '1';
                r_we(c_NK+3) <= '1';
                r_modcnt   <= 0;
                r_rcon     <= 1;
                -- First derived key index for o_rk_wr_addr (K_1 of AES-256
                -- goes out already on this LOAD cycle, straight from i_key)
                if c_NK = 8 then
                    r_out_addr <= 2;
                else
                    r_out_addr <= 1;
                end if;

            elsif state_reg = S_EXPANDING then
                ---------------------------------------------------------------
                -- COMPUTE four words: the w_w0..w_w3 bundle is combinational
                -- (shared with the o_rk_wr_* stream), this branch only
                -- registers it.
                ---------------------------------------------------------------
                -- Shift window by 4 (empty loop for Nk=4), insert new 4 words
                for k in 0 to c_NK-5 loop
                    r_window(k) <= r_window(k+4);
                end loop;
                r_window(c_NK-4) <= w_w0;
                r_window(c_NK-3) <= w_w1;
                r_window(c_NK-2) <= w_w2;
                r_window(c_NK-1) <= w_w3;

                -- Drive the four new words to their fixed slots via CE
                for j in 4 to 59 loop
                    if r_we(j) = '1' then
                        case j mod 4 is
                            when 0      => r_rk(j) <= w_w0;
                            when 1      => r_rk(j) <= w_w1;
                            when 2      => r_rk(j) <= w_w2;
                            when others => r_rk(j) <= w_w3;
                        end case;
                    end if;
                end loop;

                -- Walking-4 strobe shift
                r_we <= "0000" & r_we(4 to 55);

                -- Next derived key index (saturates harmlessly; the state
                -- machine leaves S_EXPANDING right after the last key)
                if r_out_addr < 15 then
                    r_out_addr <= r_out_addr + 1;
                end if;

                -- Counter updates (skip on the last cycle to keep r_rcon in range)
                if w_is_last = '0' then
                    if r_modcnt + 4 >= c_NK then
                        r_modcnt <= 0;
                    else
                        r_modcnt <= r_modcnt + 4;
                    end if;
                    if r_modcnt = 0 then
                        r_rcon <= r_rcon + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_DATAPATH;

    ---------------------------------------------------------------------------
    -- Output mapping
    --   o_round_keys(0)      = K0 (initial AddRoundKey, latched i_key MSB half)
    --   o_round_keys(1..14)  = derived round keys, each = W[4*j .. 4*j+3]
    -- Constant indices => direct wires, no run-time mux.
    ---------------------------------------------------------------------------
    o_round_keys(0) <= r_k0;
    gen_out_keys : for j in 1 to 14 generate
        o_round_keys(j) <= r_rk(4*j) & r_rk(4*j+1) & r_rk(4*j+2) & r_rk(4*j+3);
    end generate gen_out_keys;

end architecture;
