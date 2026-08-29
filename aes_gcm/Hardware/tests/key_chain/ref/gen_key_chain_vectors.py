#!/usr/bin/env python3
"""
Company  : University of Belgrade, School of Electrical Engineering (ETF)
Engineer : Marko Gavrilović
Email    : markog0403@gmail.com

Golden-vector generator for the key-derivation-and-use chain testbench
(tests/key_chain/tb/tb_key_chain.vhd). Emits one VHDL package,
tb/tb_key_chain_vectors_pkg.vhd, holding every constant the testbench
compares against, so the testbench itself contains no magic numbers.

The scenario is the target chain organisation of the thesis (fig:hw_lanac):
two parties, A and B, each with a private scalar, run ECDH over NIST B-571,
derive a 256-bit session key with KMAC256 used as a one-step KDF per
SP 800-56C (N = "KMAC", S = "KDF", K = 32-byte public salt,
X = Z || FixedInfo, L = 256), and protect packets with AES-256-GCM.

Reference models, all taken from this repository:
  * ECDH        : ecdh/Software/Python/ec_ladder.py + gf2m.py (imported here);
                  the NIST B-571 curve constants below are validated against
                  the curve equation y^2 + xy = x^3 + x^2 + b before use.
  * cSHAKE/KMAC : the Keccak core and SP 800-185 framing functions are copied
                  verbatim from sha3/Hardware/sim/gen_cshake_vectors.py; the
                  core is re-validated against hashlib here, and the framing
                  is re-validated by regenerating every case of
                  sha3/Hardware/sim/cshake256_kat_512.txt and comparing
                  byte-for-byte against the checked-in vector file.
  * AES-256-GCM : the Python 'cryptography' package (same reference the
                  tests/l3_full_chain KAT suite uses).

Byte-order conventions (must match the RTL, see tests/key_chain/README.md):
  * Z leaves m_axis_z of ecdh_axis_ip as ceil(571/32) = 18 words of 32 bits,
    LSB word first, little-endian byte lanes -> the 72-byte string absorbed
    into the KDF message is the little-endian encoding of the integer x(S).
  * The KMAC frame is byte-identical to what gen_cshake_vectors.py produces:
    bytepad(encode_string("KMAC") + encode_string("KDF"), 136)
    || bytepad(encode_string(salt), 136) || Z || FixedInfo || right_encode(256).
  * The session key K is used in spec order: its first byte maps to
    i_key(255 downto 248) of the GCM tops (KEY_REV = 0 convention proven by
    the tests/l3_full_chain KAT suite).

Usage: python3 gen_key_chain_vectors.py
Writes ../tb/tb_key_chain_vectors_pkg.vhd. Deterministic: no timestamps,
no randomness outside the fixed derivations below.
"""
import hashlib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]                      # repo root
sys.path.insert(0, str(REPO / "ecdh" / "Software" / "Python"))

from gf2m import gf_add, gf_mul, gf_sqr, M_B571, F_B571     # noqa: E402
from ec_ladder import scalar_mult_ct, Mxy                   # noqa: E402

# ---------------------------------------------------------------------------
# Keccak core + SP 800-185 helpers, copied verbatim from
# sha3/Hardware/sim/gen_cshake_vectors.py (the project's cSHAKE/KMAC
# reference). Both are re-validated below before anything is emitted.
# ---------------------------------------------------------------------------
MASK = (1 << 64) - 1

RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
      0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
      0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
      0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
      0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
      0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]

ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
       [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]  # ROT[x][y]


def rol(v, n):
    n %= 64
    return ((v << n) | (v >> (64 - n))) & MASK if n else v


def keccak_f(A):
    for rc in RC:
        C = [A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4] for x in range(5)]
        D = [C[(x - 1) % 5] ^ rol(C[(x + 1) % 5], 1) for x in range(5)]
        A = [[A[x][y] ^ D[x] for y in range(5)] for x in range(5)]
        B = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                B[y][(2 * x + 3 * y) % 5] = rol(A[x][y], ROT[x][y])
        A = [[B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y]) for y in range(5)]
             for x in range(5)]
        A[0][0] ^= rc
    return A


def keccak(rate_bytes, msg, suffix, out_len):
    """Sponge: absorb msg + pad(suffix..0x80), squeeze out_len bytes."""
    A = [[0] * 5 for _ in range(5)]
    m = bytearray(msg)
    m.append(suffix)
    while len(m) % rate_bytes:
        m.append(0)
    m[-1] |= 0x80
    for off in range(0, len(m), rate_bytes):
        for i in range(rate_bytes // 8):
            x, y = i % 5, i // 5
            A[x][y] ^= int.from_bytes(m[off + 8 * i:off + 8 * i + 8], 'little')
        A = keccak_f(A)
    out = bytearray()
    while True:
        for i in range(rate_bytes // 8):
            x, y = i % 5, i // 5
            out += A[x][y].to_bytes(8, 'little')
        if len(out) >= out_len:
            return bytes(out[:out_len])
        A = keccak_f(A)


def left_encode(n):
    b = n.to_bytes(max(1, (n.bit_length() + 7) // 8), 'big')
    return bytes([len(b)]) + b


def right_encode(n):
    b = n.to_bytes(max(1, (n.bit_length() + 7) // 8), 'big')
    return b + bytes([len(b)])


def encode_string(s: bytes):
    return left_encode(8 * len(s)) + s


def bytepad(x: bytes, w: int):
    z = left_encode(w) + x
    return z + b'\x00' * ((-len(z)) % w)


def cshake_prefix(rate_bytes, N: bytes, S: bytes):
    """The block the framing logic prepends to the message (rate-aligned)."""
    return bytepad(encode_string(N) + encode_string(S), rate_bytes)


def cshake(rate_bytes, X: bytes, L_bytes: int, N: bytes, S: bytes):
    if not N and not S:                       # spec: falls back to plain SHAKE
        return keccak(rate_bytes, X, 0x1F, L_bytes)
    return keccak(rate_bytes, cshake_prefix(rate_bytes, N, S) + X, 0x04, L_bytes)


def kmac_msg(rate_bytes, K: bytes, X: bytes, L_bits: int):
    """KMAC body (everything after the N/S prefix block)."""
    return bytepad(encode_string(K), rate_bytes) + X + right_encode(L_bits)


# ---------------------------------------------------------------------------
# Self-check 1: Keccak core against hashlib (same check the SHA3 reference
# generator performs before it emits anything).
# ---------------------------------------------------------------------------
for name, rate, suf, ln in [('sha3_256', 136, 0x06, 32), ('sha3_512', 72, 0x06, 64)]:
    for msg in [b'', b'abc', bytes(200 * [0xA3]), bytes(range(rate - 1)), bytes(range(rate))]:
        assert keccak(rate, msg, suf, ln) == getattr(hashlib, name)(msg).digest(), name
for name, rate in [('shake_128', 168), ('shake_256', 136)]:
    for msg in [b'', b'abc', bytes(range(135))]:
        assert keccak(rate, msg, 0x1F, 300) == getattr(hashlib, name)(msg).digest(300), name
print("Keccak core validated against hashlib (SHA3-256/512, SHAKE128/256)")

# ---------------------------------------------------------------------------
# Self-check 2: the copied framing regenerates the checked-in cSHAKE/KMAC KAT
# file byte-for-byte, so this generator and the SHA3 KAT reference are one
# and the same convention.
# ---------------------------------------------------------------------------
R256 = 136
kat_cases = []
N, S, X = b"", b"Email Signature", bytes(range(4))
kat_cases.append((cshake_prefix(R256, N, S) + X, cshake(R256, X, 64, N, S)))
N, S, X = b"", b"ETF KDF v1", bytes([0xA3] * 200)
kat_cases.append((cshake_prefix(R256, N, S) + X, cshake(R256, X, 64, N, S)))
K, S, X, Lb = bytes(range(0x40, 0x60)), b"My Tagged Application", bytes(range(4)), 512
body = kmac_msg(R256, K, X, Lb)
kat_cases.append((cshake_prefix(R256, b"KMAC", S) + body,
                  cshake(R256, body, Lb // 8, b"KMAC", S)))
N, S = b"", b"pad"
X = bytes(i & 0xFF for i in range(2 * R256 - 1 - len(cshake_prefix(R256, N, S))))
kat_cases.append((cshake_prefix(R256, N, S) + X, cshake(R256, X, 64, N, S)))

kat_file = REPO / "sha3" / "Hardware" / "sim" / "cshake256_kat_512.txt"
kat_lines = kat_file.read_text().split()
assert len(kat_lines) == 2 * len(kat_cases), "unexpected KAT file shape"
for i, (msg, exp) in enumerate(kat_cases):
    assert kat_lines[2 * i] == msg.hex(), f"KAT msg mismatch, case {i + 1}"
    assert kat_lines[2 * i + 1] == exp.hex(), f"KAT out mismatch, case {i + 1}"
print(f"cSHAKE/KMAC framing validated against {kat_file.name} (4 cases)")

# ---------------------------------------------------------------------------
# ECDH over NIST B-571: curve constants (FIPS 186-4, a = 1) validated against
# the curve equation, then both key pairs and the shared secret.
# ---------------------------------------------------------------------------
M, F = M_B571, F_B571
CURVE_B = 0x02F40E7E2221F295DE297117B7F3D62F5C6A97FFCB8CEFF1CD6BA8CE4A9A18AD84FFABBD8EFA59332BE7AD6756A66E294AFD185A78FF12AA520E4DE739BACA0C7FFEFF7F2955727A
G_X = 0x0303001D34B856296C16C0D40D3CD7750A93D1D2955FA80AA5F40FC8DB7B2ABDBDE53950F4C0D293CDD711A35B67FB1499AE60038614F1394ABFA3B4C850D927E1E7769C8EEC2D19
G_Y = 0x037BF27342DA639B6DCCFFFEB73D69D78C6C27A6009CBBCA1980F8533921E8A684423E43BAB08A576291AF8F461BB2A8B3531D2F0485C19B16E2F1516E23DD3C1A4827AF1B8AC15B

lhs = gf_add(gf_sqr(G_Y, M, F), gf_mul(G_X, G_Y, M, F))
rhs = gf_add(gf_add(gf_mul(gf_sqr(G_X, M, F), G_X, M, F), gf_sqr(G_X, M, F)), CURVE_B)
assert lhs == rhs, "B-571 base point does not satisfy y^2 + xy = x^3 + x^2 + b"
print("NIST B-571 constants validated against the curve equation")


def kP(k, px, py):
    """Affine k*P via the constant-time ladder + y-recovery (golden model)."""
    X1, Z1, X2, Z2 = scalar_mult_ct(k, px, py, 1, CURVE_B, M, F)
    assert Z1 != 0 and Z2 != 0, "ladder edge case hit (Z = 0)"
    return Mxy(X1, Z1, X2, Z2, px, py, M, F)


# Private scalars: fixed, full 571-bit values (deterministic derivation).
D_A = (int.from_bytes(hashlib.shake_256(b"key_chain side A scalar").digest(72), 'big')
       % (1 << 571)) | (1 << 570) | 1
D_B = (int.from_bytes(hashlib.shake_256(b"key_chain side B scalar").digest(72), 'big')
       % (1 << 571)) | (1 << 570) | 1

QA_X, QA_Y = kP(D_A, G_X, G_Y)           # A's public key  Q_A = d_A * G
QB_X, QB_Y = kP(D_B, G_X, G_Y)           # B's public key  Q_B = d_B * G
ZA, _ = kP(D_A, QB_X, QB_Y)              # A's view: x(d_A * Q_B)
ZB, _ = kP(D_B, QA_X, QA_Y)              # B's view: x(d_B * Q_A)
assert ZA == ZB, "shared secret mismatch between the two sides"
Z = ZA
print("ECDH golden values computed (both sides agree on Z)")

# ---------------------------------------------------------------------------
# KMAC256 as a one-step KDF (SP 800-56C), the exact roles of thesis
# example 3.1: K = 32-byte public salt, X = Z || FixedInfo (72 + 40 bytes),
# S = "KDF", L = 256 bits. Z is the byte stream exactly as it leaves
# m_axis_z: little-endian encoding in 18 x 32-bit words = 72 bytes.
# ---------------------------------------------------------------------------
SALT = bytes(range(0xA0, 0xC0))                       # 32-byte public salt
FIXED_INFO = b"ETF-MR ECDH-B571 KMAC256 KDF sides A|B ".ljust(40)
assert len(FIXED_INFO) == 40

Z_BYTES = Z.to_bytes(72, 'little')                    # 18 words x 4 bytes
X_KDF = Z_BYTES + FIXED_INFO                          # 112 bytes, as in ex. 3.1
L_BITS = 256

FRAME_HEAD = cshake_prefix(R256, b"KMAC", b"KDF") + bytepad(encode_string(SALT), R256)
FRAME_TAIL = FIXED_INFO + right_encode(L_BITS)
assert len(FRAME_HEAD) == 272 and len(FRAME_TAIL) == 43

kdf_msg = kmac_msg(R256, SALT, X_KDF, L_BITS)
assert cshake_prefix(R256, b"KMAC", b"KDF") + kdf_msg == FRAME_HEAD + Z_BYTES + FRAME_TAIL
SESSION_KEY = cshake(R256, kdf_msg, L_BITS // 8, b"KMAC", b"KDF")
print("session key K =", SESSION_KEY.hex())

# ---------------------------------------------------------------------------
# AES-256-GCM: one packet per direction, IPsec ESP tunnel geometry of the
# ipsec_chain suite (34 bypass bytes, 16 AAD bytes), different nonce and
# payload length per direction. Reference: the 'cryptography' package.
# ---------------------------------------------------------------------------
from cryptography.hazmat.primitives.ciphers.aead import AESGCM   # noqa: E402

BYPASS, AAD = 34, 16
PT_AB, PT_BA = 64, 40
NONCE_AB = bytes(range(0xA0, 0xAC))
NONCE_BA = bytes(range(0xB0, 0xBC))

PKT_AB = bytes((7 * i + 13) % 256 for i in range(BYPASS + AAD + PT_AB))
PKT_BA = bytes((11 * i + 29) % 256 for i in range(BYPASS + AAD + PT_BA))


def protect(pkt, nonce):
    hdr, aad, pt = pkt[:BYPASS], pkt[BYPASS:BYPASS + AAD], pkt[BYPASS + AAD:]
    return hdr + aad + AESGCM(SESSION_KEY).encrypt(nonce, pt, aad)   # ct || tag


PROT_AB = protect(PKT_AB, NONCE_AB)
PROT_BA = protect(PKT_BA, NONCE_BA)
print("AES-256-GCM golden packets computed (A->B and B->A)")

# ---------------------------------------------------------------------------
# Emit the VHDL package.
# ---------------------------------------------------------------------------


def slv_bin(name, value, width, comment):
    """A (width-1 downto 0) constant as wrapped binary string literals."""
    bits = format(value, f"0{width}b")
    assert len(bits) == width
    chunks = [bits[i:i + 80] for i in range(0, width, 80)]
    lines = [f"    -- {comment}",
             f"    constant {name} : std_logic_vector({width - 1} downto 0) :="]
    for i, ch in enumerate(chunks):
        tail = ";" if i == len(chunks) - 1 else " &"
        lines.append(f'        "{ch}"{tail}')
    return "\n".join(lines) + "\n"


def byte_arr(name, data, comment):
    """A byte_arr_t(0 to len-1) constant, twelve bytes per line."""
    lines = [f"    -- {comment} ({len(data)} bytes)",
             f"    constant {name} : byte_arr_t(0 to {len(data) - 1}) := ("]
    for i in range(0, len(data), 12):
        row = ", ".join(f'x"{b:02X}"' for b in data[i:i + 12])
        tail = ");" if i + 12 >= len(data) else ","
        lines.append(f"        {row}{tail}")
    return "\n".join(lines) + "\n"


def slv_hex(name, data, comment):
    """A (8*len-1 downto 0) constant in spec order (byte 0 in the top bits)."""
    return (f"    -- {comment}\n"
            f"    constant {name} : std_logic_vector({8 * len(data) - 1} downto 0) :="
            f' x"{data.hex().upper()}";\n')


header = f"""\
----------------------------------------------------------------------------------
-- Company       : University of Belgrade, School of Electrical Engineering (ETF)
-- Engineer      : Marko Gavrilović
-- Email         : markog0403@gmail.com
--
-- Create Date   : August 2026
-- Design Name   : tb_key_chain_vectors_pkg
-- Module Name   : tb_key_chain_vectors_pkg - package
-- Tool Version  : Vivado Simulator 2025.1 (xvhdl -2008 / xelab / xsim)
--
-- Description   : Golden values for tb_key_chain, GENERATED by
--                 ref/gen_key_chain_vectors.py -- do not edit by hand,
--                 regenerate instead. The generator validates its Keccak
--                 core against hashlib, its cSHAKE/KMAC framing against the
--                 checked-in SHA3 KAT vectors, and the B-571 constants
--                 against the curve equation before emitting this file.
--
--                 Wide field elements are (570 downto 0) binary literals,
--                 bit i of the literal = bit i of the field element, the
--                 order every ECDH port uses. Byte arrays are in wire order
--                 (index 0 is the first byte on the stream). C_SESSION_KEY
--                 and the nonces are in spec order: byte 0 in the top bits,
--                 the KEY_REV = 0 convention of the GCM KAT suite.
--
-- Revision      :
--   0.01 - August 2026 - File Created (generated)
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

package tb_key_chain_vectors_pkg is

    type byte_arr_t is array (natural range <>) of std_logic_vector(7 downto 0);

    ----------------------------------------------------------------------------
    -- Packet geometry (bytes) and KMAC frame section lengths
    ----------------------------------------------------------------------------
    constant C_BYPASS_BYTES : integer := {BYPASS};
    constant C_AAD_BYTES    : integer := {AAD};
    constant C_PT_AB_BYTES  : integer := {PT_AB};
    constant C_PT_BA_BYTES  : integer := {PT_BA};
    constant C_ICV_BYTES    : integer := 16;

    -- KMAC frame: head = prefix block || key (salt) block, then Z (72 bytes
    -- straight from m_axis_z), then tail = FixedInfo || right_encode(L)
    constant C_FRAME_HEAD_BYTES : integer := {len(FRAME_HEAD)};
    constant C_Z_BYTES          : integer := {len(Z_BYTES)};
    constant C_FRAME_TAIL_BYTES : integer := {len(FRAME_TAIL)};

"""

out = [header]
out.append(slv_bin("C_CURVE_B", CURVE_B, 571, "NIST B-571 curve parameter b (a = 1)"))
out.append("\n")
out.append(slv_bin("C_G_X", G_X, 571, "NIST B-571 base point G, x coordinate"))
out.append("\n")
out.append(slv_bin("C_G_Y", G_Y, 571, "NIST B-571 base point G, y coordinate"))
out.append("\n")
out.append(slv_bin("C_SCALAR_A", D_A, 571, "side A private scalar d_A"))
out.append("\n")
out.append(slv_bin("C_SCALAR_B", D_B, 571, "side B private scalar d_B"))
out.append("\n")
out.append(slv_bin("C_QA_X", QA_X, 571, "expected public key Q_A = d_A * G, x"))
out.append("\n")
out.append(slv_bin("C_QA_Y", QA_Y, 571, "expected public key Q_A = d_A * G, y"))
out.append("\n")
out.append(slv_bin("C_QB_X", QB_X, 571, "expected public key Q_B = d_B * G, x"))
out.append("\n")
out.append(slv_bin("C_QB_Y", QB_Y, 571, "expected public key Q_B = d_B * G, y"))
out.append("\n")
out.append(slv_bin("C_Z", Z, 571, "expected shared secret Z = x(d_A * d_B * G)"))
out.append("\n")
out.append(byte_arr("C_FRAME_HEAD", FRAME_HEAD,
                    "KMAC frame head: bytepad(encode_string(\"KMAC\") || "
                    "encode_string(\"KDF\"), 136) || bytepad(encode_string(salt), 136)"))
out.append("\n")
out.append(byte_arr("C_FRAME_TAIL", FRAME_TAIL,
                    "KMAC frame tail: FixedInfo (40 bytes) || right_encode(256)"))
out.append("\n")
out.append(slv_hex("C_SESSION_KEY", SESSION_KEY,
                   "expected session key K = KMAC256(salt, Z || FixedInfo, 256, \"KDF\")"))
out.append("\n")
out.append(slv_hex("C_NONCE_AB", NONCE_AB, "GCM nonce for the A -> B packet"))
out.append(slv_hex("C_NONCE_BA", NONCE_BA, "GCM nonce for the B -> A packet"))
out.append("\n")
out.append(byte_arr("C_PKT_AB", PKT_AB, "plain A -> B packet: bypass || AAD || PT"))
out.append("\n")
out.append(byte_arr("C_PROT_AB", PROT_AB,
                    "expected protected A -> B packet: bypass || AAD || CT || ICV"))
out.append("\n")
out.append(byte_arr("C_PKT_BA", PKT_BA, "plain B -> A packet: bypass || AAD || PT"))
out.append("\n")
out.append(byte_arr("C_PROT_BA", PROT_BA,
                    "expected protected B -> A packet: bypass || AAD || CT || ICV"))
out.append("\nend package;\n")

pkg_path = HERE.parent / "tb" / "tb_key_chain_vectors_pkg.vhd"
pkg_path.parent.mkdir(parents=True, exist_ok=True)
pkg_path.write_text("".join(out))
print(f"wrote {pkg_path}")
