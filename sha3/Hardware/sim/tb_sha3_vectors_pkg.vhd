----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : July 2026
-- Design Name   : tb_sha3_vectors_pkg
-- Module Name   : tb_sha3_vectors_pkg - sim
-- Tool Version  : GHDL (--std=08 -fsynopsys)
--
-- Description   : NIST/hashlib reference vectors for the SHA-3 KAT TB
--                 Four messages per variant, chosen to hit distinct padding paths:
--                 msg 1: "abc"                       (partial last word -> TKEEP handling)
--                 msg 2: 200 bytes of 0xA3           (multi-block, full last word)
--                 msg 3: rate-length message         (extra padding-only block path)
--                 msg 4: (rate-1)-length message     (0x06 and 0x80 merge into one 0x86 byte)
--                 Messages 3/4 use the incrementing byte pattern (idx mod 256).
--                 Digests computed with Python hashlib (sha3_224/256/384/512) and written
--                 in natural reading order: first digest byte = most significant hex pair.
--
-- Revision      :
--   0.01 - July 2026 - File Created
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package tb_sha3_vectors_pkg is

    function rate_bytes(ver : string) return integer;
    function digest_bits(ver : string) return integer;
    function msg_len(msg_id : integer; ver : string) return integer;
    function msg_byte(msg_id : integer; idx : integer) return std_logic_vector;
    function expected_digest(ver : string; msg_id : integer) return std_logic_vector;

end package;

package body tb_sha3_vectors_pkg is

    ---------------------------------------------------------------------------
    -- Geometry helpers
    ---------------------------------------------------------------------------
    function digest_bits(ver : string) return integer is
    begin
        if    ver = "224" then return 224;
        elsif ver = "256" then return 256;
        elsif ver = "384" then return 384;
        else                   return 512;
        end if;
    end function;

    function rate_bytes(ver : string) return integer is
    begin
        return (1600 - 2 * digest_bits(ver)) / 8;
    end function;

    ---------------------------------------------------------------------------
    -- Message generators
    ---------------------------------------------------------------------------
    function msg_len(msg_id : integer; ver : string) return integer is
    begin
        case msg_id is
            when 1      => return 3;
            when 2      => return 200;
            when 3      => return rate_bytes(ver);
            when others => return rate_bytes(ver) - 1;
        end case;
    end function;

    function msg_byte(msg_id : integer; idx : integer) return std_logic_vector is
    begin
        case msg_id is
            when 1 =>
                case idx is
                    when 0      => return x"61";  -- 'a'
                    when 1      => return x"62";  -- 'b'
                    when others => return x"63";  -- 'c'
                end case;
            when 2      => return x"A3";
            when others => return std_logic_vector(to_unsigned(idx mod 256, 8));
        end case;
    end function;

    ---------------------------------------------------------------------------
    -- Reference digests (python3 hashlib, 2026-06-12)
    ---------------------------------------------------------------------------
    -- SHA3-224
    constant c_D224_1 : std_logic_vector(223 downto 0) := x"e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf";
    constant c_D224_2 : std_logic_vector(223 downto 0) := x"9376816aba503f72f96ce7eb65ac095deee3be4bf9bbc2a1cb7e11e0";
    constant c_D224_3 : std_logic_vector(223 downto 0) := x"5be75e6a08f19913a1d8036c056cc4556b98dc90aeca3f2a0664dedc";
    constant c_D224_4 : std_logic_vector(223 downto 0) := x"64d0e8a1be3cf30ef6727b30a6e428f7f068d44634c943d277ad8e7f";
    -- SHA3-256
    constant c_D256_1 : std_logic_vector(255 downto 0) := x"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
    constant c_D256_2 : std_logic_vector(255 downto 0) := x"79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787";
    constant c_D256_3 : std_logic_vector(255 downto 0) := x"cf3ccff92480a29160c2d38317c430e14749bfee1788106957dfe73f8c4930e5";
    constant c_D256_4 : std_logic_vector(255 downto 0) := x"fded8fd9d6551c601eeb3b7c6bc5e5cfd8aad1d015b7e9aaa9c9b9475231d5e2";
    -- SHA3-384
    constant c_D384_1 : std_logic_vector(383 downto 0) := x"ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25";
    constant c_D384_2 : std_logic_vector(383 downto 0) := x"1881de2ca7e41ef95dc4732b8f5f002b189cc1e42b74168ed1732649ce1dbcdd76197a31fd55ee989f2d7050dd473e8f";
    constant c_D384_3 : std_logic_vector(383 downto 0) := x"5b8d0d5cf8b41be507be8fcbfcbdbac3a28eb368d430fed6780aaa78a93a8da4a6c50485949ca344f228be91a96005a3";
    constant c_D384_4 : std_logic_vector(383 downto 0) := x"1f91ee551ad18f268876d1fc262f137fe196580216c5193819a95ec5222537d2a658dd129c3d8080e65ec7460f1f4704";
    -- SHA3-512
    constant c_D512_1 : std_logic_vector(511 downto 0) := x"b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0";
    constant c_D512_2 : std_logic_vector(511 downto 0) := x"e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca81b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00";
    constant c_D512_3 : std_logic_vector(511 downto 0) := x"5d63f2bbe971a983ac6847480106e4e1264ee3a0befd79954914e1d86e795b2e18238f12fc5e46cb9cc78efdec610a93647cc04e1c23d8caaa6a58c21dd26c07";
    constant c_D512_4 : std_logic_vector(511 downto 0) := x"3ccc850d53a1287af7b4560b2ef0d43eb5d9a80d62a0e9cf1dbc040135921104d4395168e90bfc871773ebb34bca1bd67056e1cc7dc7a48ff7c3167d389f117c";

    function expected_digest(ver : string; msg_id : integer) return std_logic_vector is
    begin
        if ver = "224" then
            case msg_id is
                when 1      => return c_D224_1;
                when 2      => return c_D224_2;
                when 3      => return c_D224_3;
                when others => return c_D224_4;
            end case;
        elsif ver = "256" then
            case msg_id is
                when 1      => return c_D256_1;
                when 2      => return c_D256_2;
                when 3      => return c_D256_3;
                when others => return c_D256_4;
            end case;
        elsif ver = "384" then
            case msg_id is
                when 1      => return c_D384_1;
                when 2      => return c_D384_2;
                when 3      => return c_D384_3;
                when others => return c_D384_4;
            end case;
        else
            case msg_id is
                when 1      => return c_D512_1;
                when 2      => return c_D512_2;
                when 3      => return c_D512_3;
                when others => return c_D512_4;
            end case;
        end if;
    end function;

end package body;
