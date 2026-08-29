#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# Company  : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer : Marko Gavrilović
# Email    : markog0403@gmail.com
#
# AES-256 round algorithm — the plug-in cipher provider for gcm_ref.py.
# ---------------------------------------------------------------------------

NAME       = 'AES'
KEY_BITS   = 256
NUM_ROUNDS = 14          # Nr for AES-256; expand_key returns NUM_ROUNDS + 1 keys

SBOX = bytes.fromhex(
    '637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0'
    'b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275'
    '09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf'
    'd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2'
    'cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb'
    'e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08'
    'ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e'
    'e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16')

RCON = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40]


def _xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


def _xtime(a):
    a <<= 1
    return (a ^ 0x1b) & 0xff if a & 0x100 else a


def _mul(a, b):
    p = 0
    while b:
        if b & 1:
            p ^= a
        a = _xtime(a)
        b >>= 1
    return p


def _sub_bytes(s):
    return bytes(SBOX[b] for b in s)


def _shift_rows(s):
    o = bytearray(16)
    for r in range(4):
        for c in range(4):
            o[r + 4 * c] = s[r + 4 * ((c + r) % 4)]
    return bytes(o)


def _mix_columns(s):
    o = bytearray(16)
    for c in range(4):
        a0, a1, a2, a3 = s[4 * c:4 * c + 4]
        o[4 * c + 0] = _mul(a0, 2) ^ _mul(a1, 3) ^ a2 ^ a3
        o[4 * c + 1] = a0 ^ _mul(a1, 2) ^ _mul(a2, 3) ^ a3
        o[4 * c + 2] = a0 ^ a1 ^ _mul(a2, 2) ^ _mul(a3, 3)
        o[4 * c + 3] = _mul(a0, 3) ^ a1 ^ a2 ^ _mul(a3, 2)
    return bytes(o)


# --- API functions -----------------------------------------------------------

def expand_key(key: bytes) -> list:
    assert len(key) == KEY_BITS // 8, f'AES-256 needs a {KEY_BITS // 8}-byte key'
    nk = 8
    words = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
    for i in range(nk, 4 * (NUM_ROUNDS + 1)):
        t = list(words[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]
            t = [SBOX[b] for b in t]
            t[0] ^= RCON[i // nk]
        elif i % nk == 4:
            t = [SBOX[b] for b in t]
        words.append([words[i - nk][j] ^ t[j] for j in range(4)])
    return [bytes(words[4 * r + c][b] for c in range(4) for b in range(4))
            for r in range(NUM_ROUNDS + 1)]


def round(state: bytes, round_key: bytes) -> bytes:
    """One main round: SubBytes -> ShiftRows -> MixColumns -> AddRoundKey."""
    return _xor(_mix_columns(_shift_rows(_sub_bytes(state))), round_key)


def final_round(state: bytes, round_key: bytes) -> bytes:
    """The last round has no MixColumns."""
    return _xor(_shift_rows(_sub_bytes(state)), round_key)


def encrypt_block(block: bytes, round_keys: list) -> bytes:
    state = _xor(block, round_keys[0])
    for i in range(1, NUM_ROUNDS):
        state = round(state, round_keys[i])
    return final_round(state, round_keys[NUM_ROUNDS])
