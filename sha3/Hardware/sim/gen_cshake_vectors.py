#!/usr/bin/env python3
"""Reference model + KAT vector generator for the cSHAKE/KMAC configuration.

The Keccak core below is validated against hashlib (SHA3-256/512, SHAKE128/256
must match bit-exact) before any cSHAKE vector is emitted, so the cSHAKE/KMAC
references are trustworthy without pycryptodome.

Also serves as the reference for host-side cSHAKE/KMAC framing:
from the accelerator's point of view cSHAKE/KMAC is just ALGORITHM=CSHAKE
(pad byte 0x04) plus message bytes prepared by software:
    cSHAKE: bytepad(encode_string(N) + encode_string(S), rate) + X
    KMAC:   cSHAKE(N="KMAC", S=S) over bytepad(encode_string(K), rate) + X
            + right_encode(L)   (right_encode(0) for the XOF variant)

Vector file format (read by tb_cshake_kat.vhd): two lines per case --
line 1 = full DUT message in hex (exactly what goes over AXIS), line 2 =
expected output in hex (G_OUT_BITS bits).
"""
import hashlib
from pathlib import Path

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


# --- SP 800-185 string encodings -------------------------------------------
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
    """The block software prepends to the message (rate-aligned)."""
    return bytepad(encode_string(N) + encode_string(S), rate_bytes)


def cshake(rate_bytes, X: bytes, L_bytes: int, N: bytes, S: bytes):
    if not N and not S:                       # spec: falls back to plain SHAKE
        return keccak(rate_bytes, X, 0x1F, L_bytes)
    return keccak(rate_bytes, cshake_prefix(rate_bytes, N, S) + X, 0x04, L_bytes)


def kmac_msg(rate_bytes, K: bytes, X: bytes, L_bits: int):
    """KMAC body (everything after the N/S prefix): software-side formatting."""
    return bytepad(encode_string(K), rate_bytes) + X + right_encode(L_bits)


# --- validate the core against hashlib BEFORE emitting anything -------------
for name, rate, suf, ln in [('sha3_256', 136, 0x06, 32), ('sha3_512', 72, 0x06, 64)]:
    for m in [b'', b'abc', bytes(200 * [0xA3]), bytes(range(rate - 1)), bytes(range(rate))]:
        assert keccak(rate, m, suf, ln) == getattr(hashlib, name)(m).digest(), name
for name, rate in [('shake_128', 168), ('shake_256', 136)]:
    for m in [b'', b'abc', bytes(range(135))]:
        assert keccak(rate, m, 0x1F, 300) == getattr(hashlib, name)(m).digest(300), name
print("Keccak core validated against hashlib (SHA3-256/512, SHAKE128/256)")

# --- emit vector files -------------------------------------------------------
SIM = str(Path(__file__).resolve().parent) + '/'


def emit(fname, cases):
    with open(SIM + fname, 'w') as f:
        for msg, exp in cases:
            f.write(msg.hex() + "\n")
            f.write(exp.hex() + "\n")
    print(f"wrote {fname} ({len(cases)} cases)")


R256, R128 = 136, 168

# cSHAKE256, L = 512 bits
cases = []
# 1) classic sample shape: N="", S="Email Signature", X=00010203
N, S, X = b"", b"Email Signature", bytes(range(4))
cases.append((cshake_prefix(R256, N, S) + X, cshake(R256, X, 64, N, S)))
# 2) KDF-style: longer X
N, S, X = b"", b"ETF KDF v1", bytes([0xA3] * 200)
cases.append((cshake_prefix(R256, N, S) + X, cshake(R256, X, 64, N, S)))
# 3) KMAC256 (N="KMAC"): key block + X + right_encode(L) -- pure SW formatting
K, S, X, Lb = bytes(range(0x40, 0x60)), b"My Tagged Application", bytes(range(4)), 512
body = kmac_msg(R256, K, X, Lb)
cases.append((cshake_prefix(R256, b"KMAC", S) + body,
              cshake(R256, body, Lb // 8, b"KMAC", S)))
# 4) total message length = 2*rate - 1 -> 0x84 merge byte (0x04 | 0x80)
N, S = b"", b"pad"
X = bytes(i & 0xFF for i in range(2 * R256 - 1 - len(cshake_prefix(R256, N, S))))
cases.append((cshake_prefix(R256, N, S) + X, cshake(R256, X, 64, N, S)))
emit('cshake256_kat_512.txt', cases)

# cSHAKE256, L = 2048 bits (multi-squeeze: 2 chunks of rate 1088)
cases = []
N, S, X = b"", b"XOF long", b"abc"
cases.append((cshake_prefix(R256, N, S) + X, cshake(R256, X, 256, N, S)))
# KMACXOF256: right_encode(0) instead of right_encode(L)
K, S, X = bytes(range(0x40, 0x60)), b"My Tagged Application", bytes(range(4))
body = kmac_msg(R256, K, X, 0)
cases.append((cshake_prefix(R256, b"KMAC", S) + body,
              cshake(R256, body, 256, b"KMAC", S)))
emit('cshake256_kat_2048.txt', cases)

# cSHAKE128, L = 512 bits (rate 168)
cases = []
N, S, X = b"", b"Email Signature", bytes(range(4))
cases.append((cshake_prefix(R128, N, S) + X, cshake(R128, X, 64, N, S)))
emit('cshake128_kat_512.txt', cases)
