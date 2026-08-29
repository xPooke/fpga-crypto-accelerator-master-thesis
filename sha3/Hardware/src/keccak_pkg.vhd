----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : January 2026
-- Design Name   : keccak_pkg
-- Module Name   : keccak_pkg - package
-- Tool Version  : Vivado 2025.1
--
-- Description   : Keccak-f[1600] permutation as pure functions: the theta,
--                 rho, pi, chi and iota step mappings, composed into one
--                 round by keccak_round. Holds the 24 round constants and
--                 the per-lane rotation offsets from FIPS 202.
--
-- Dependencies  : (none)
--
-- Revision      :
--   0.01 - January 2026 - File Created
--
-- Additional Comments :
--   State indexing: lane A[x,y] occupies bits (64*(5*y+x)+63 downto
--   64*(5*y+x)); bit z of a lane is bit z of that slice. This matches the
--   byte order in which sha3_input_buffer packs the message into the rate
--   portion of the state.
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package keccak_pkg is

    constant c_LANE_BITS  : integer := 64;    -- w in the spec
    constant c_STATE_BITS : integer := 1600;  -- 25 lanes of 64 bits
    constant c_NUM_ROUNDS : integer := 24;    -- Keccak-f[1600] round count

    subtype keccak_state_t is std_logic_vector(c_STATE_BITS - 1 downto 0);

    function theta(s : keccak_state_t) return keccak_state_t;
    function rho(s : keccak_state_t) return keccak_state_t;
    function pi(s : keccak_state_t) return keccak_state_t;
    function chi(s : keccak_state_t) return keccak_state_t;
    function iota(s : keccak_state_t; round_idx : integer) return keccak_state_t;

    -- One full round: iota(chi(pi(rho(theta(s)))), round_idx)
    function keccak_round(s : keccak_state_t; round_idx : integer) return keccak_state_t;

    -- Integer minimum (Vivado does not support VHDL-2008 "minimum")
    function imin(a, b : integer) return integer;

end package;

package body keccak_pkg is

    constant c_LENX : integer := 5;  -- columns
    constant c_LENY : integer := 5;  -- rows

    ----------------------------------------------------------------------------
    -- Round constants (FIPS 202, table for Keccak-f[1600])
    ----------------------------------------------------------------------------
    type rc_array_t is array (0 to c_NUM_ROUNDS - 1) of std_logic_vector(c_LANE_BITS - 1 downto 0);
    constant c_ROUND_CONST : rc_array_t := (
        x"0000000000000001", x"0000000000008082", x"800000000000808A",
        x"8000000080008000", x"000000000000808B", x"0000000080000001",
        x"8000000080008081", x"8000000000008009", x"000000000000008A",
        x"0000000000000088", x"0000000080008009", x"000000008000000A",
        x"000000008000808B", x"800000000000008B", x"8000000000008089",
        x"8000000000008003", x"8000000000008002", x"8000000000000080",
        x"000000000000800A", x"800000008000000A", x"8000000080008081",
        x"8000000000008080", x"0000000080000001", x"8000000080008008"
    );

    ----------------------------------------------------------------------------
    -- Rho rotation offsets per lane [y*5 + x] (FIPS 202)
    ----------------------------------------------------------------------------
    type offset_array_t is array (0 to 24) of integer;
    constant c_RHO_OFFSETS : offset_array_t := (
         0,  1, 62, 28, 27,   -- y=0: x=0..4
        36, 44,  6, 55, 20,   -- y=1: x=0..4
         3, 10, 43, 25, 39,   -- y=2: x=0..4
        41, 45, 15, 21,  8,   -- y=3: x=0..4
        18,  2, 61, 56, 14    -- y=4: x=0..4
    );

    -- Circular left shift of one lane by n positions (n = 0 yields identity
    -- through the null slice on the right operand)
    function rotl(lane : std_logic_vector(c_LANE_BITS - 1 downto 0); n : integer)
        return std_logic_vector is
    begin
        return lane(c_LANE_BITS - n - 1 downto 0) & lane(c_LANE_BITS - 1 downto c_LANE_BITS - n);
    end function;

    ----------------------------------------------------------------------------
    -- Theta: column parity diffusion
    -- A'[x,y,z] = A[x,y,z] xor C[x-1,z] xor C[x+1,z-1],
    -- C[x,z] = xor over all five rows of column x
    ----------------------------------------------------------------------------
    function theta(s : keccak_state_t) return keccak_state_t is
        variable v_r : keccak_state_t;
        variable v_x, v_y, v_z : integer;
        variable v_cl, v_cr : std_logic;
    begin
        for i in 0 to c_STATE_BITS - 1 loop
            v_z := i mod c_LANE_BITS;
            v_x := (i / c_LANE_BITS) mod c_LENX;
            v_y := i / (c_LANE_BITS * c_LENX);
            v_cl := '0';
            v_cr := '0';
            for row in 0 to c_LENY - 1 loop
                v_cl := v_cl xor s(c_LANE_BITS * (5 * row + ((v_x - 1 + c_LENX) mod c_LENX)) + v_z);
                v_cr := v_cr xor s(c_LANE_BITS * (5 * row + ((v_x + 1) mod c_LENX))
                                   + ((v_z - 1 + c_LANE_BITS) mod c_LANE_BITS));
            end loop;
            v_r(i) := s(i) xor v_cl xor v_cr;
        end loop;
        return v_r;
    end function;

    ----------------------------------------------------------------------------
    -- Rho: fixed circular rotation of each lane
    ----------------------------------------------------------------------------
    function rho(s : keccak_state_t) return keccak_state_t is
        variable v_r : keccak_state_t;
    begin
        for lane in 0 to 24 loop
            v_r((lane + 1) * c_LANE_BITS - 1 downto lane * c_LANE_BITS) :=
                rotl(s((lane + 1) * c_LANE_BITS - 1 downto lane * c_LANE_BITS),
                     c_RHO_OFFSETS(lane));
        end loop;
        return v_r;
    end function;

    ----------------------------------------------------------------------------
    -- Pi: lane permutation, A'[x,y,z] = A[(x + 3*y) mod 5, x, z]
    ----------------------------------------------------------------------------
    function pi(s : keccak_state_t) return keccak_state_t is
        variable v_r : keccak_state_t;
        variable v_x, v_y, v_z : integer;
    begin
        for i in 0 to c_STATE_BITS - 1 loop
            v_z := i mod c_LANE_BITS;
            v_x := (i / c_LANE_BITS) mod c_LENX;
            v_y := i / (c_LANE_BITS * c_LENX);
            v_r(i) := s(c_LENX * c_LANE_BITS * v_x
                        + c_LANE_BITS * ((v_x + 3 * v_y) mod c_LENX) + v_z);
        end loop;
        return v_r;
    end function;

    ----------------------------------------------------------------------------
    -- Chi: non-linear mixing, A'[x,y,z] = A[x,y,z] xor (not A[x+1,y,z] and A[x+2,y,z])
    ----------------------------------------------------------------------------
    function chi(s : keccak_state_t) return keccak_state_t is
        variable v_r : keccak_state_t;
        variable v_x, v_y, v_z : integer;
    begin
        for i in 0 to c_STATE_BITS - 1 loop
            v_z := i mod c_LANE_BITS;
            v_x := (i / c_LANE_BITS) mod c_LENX;
            v_y := i / (c_LANE_BITS * c_LENX);
            v_r(i) := s(i) xor
                      ((not s(c_LANE_BITS * (5 * v_y + ((v_x + 1) mod c_LENX)) + v_z)) and
                            s(c_LANE_BITS * (5 * v_y + ((v_x + 2) mod c_LENX)) + v_z));
        end loop;
        return v_r;
    end function;

    ----------------------------------------------------------------------------
    -- Iota: round constant into lane A[0,0]
    ----------------------------------------------------------------------------
    function iota(s : keccak_state_t; round_idx : integer) return keccak_state_t is
        variable v_r : keccak_state_t;
    begin
        v_r := s;
        v_r(c_LANE_BITS - 1 downto 0) :=
            s(c_LANE_BITS - 1 downto 0) xor c_ROUND_CONST(round_idx);
        return v_r;
    end function;

    function keccak_round(s : keccak_state_t; round_idx : integer) return keccak_state_t is
    begin
        return iota(chi(pi(rho(theta(s)))), round_idx);
    end function;

    function imin(a, b : integer) return integer is
    begin
        if a < b then
            return a;
        else
            return b;
        end if;
    end function;

end package body;
