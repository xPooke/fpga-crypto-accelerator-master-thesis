#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# Company  : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer : Marko Gavrilović
# Email    : markog0403@gmail.com
#
# Software reference model for the hardware GCM chain.
#
# It is the same story as the hardware, in the same order:
#
#   ENC   BYPASS || AAD || PT          ->  BYPASS || AAD || CT || ICV
#   DEC   BYPASS || AAD || CT || ICV   ->  BYPASS || AAD || PT      (+ verdict)
#
#   BYPASS   carried around the crypto core untouched   (SPLIT / skid / MERGE)
#   AAD      authenticated, not encrypted               (GHASH only)
#   PT / CT  encrypted and authenticated
#   ICV      the 16-byte tag                            (appended / checked)
#
# BYPASS_BYTES and AAD_BYTES are compile-time in the hardware, so they are
# constants here too. Neither has to be a multiple of 16.
#
# The cipher is a plug-in: alg_aes256.py. Everything below this line is
# algorithm-independent, exactly as the glue is in the hardware.
#
#   gcm_ref.py ENC AES        gcm_ref.py DEC AES       (AES is AES-256)
# ---------------------------------------------------------------------------
import argparse
import importlib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# --- the two hardware generics ---------------------------------------------
BYPASS_BYTES = 16
AAD_BYTES    = 20

# --- fixed by GCM -----------------------------------------------------------
BLOCK_BYTES = 16
TAG_BYTES   = 16

ALGORITHMS = {'AES': 'alg_aes256'}

DEFAULTS = dict(key=HERE / 'params' / 'key.txt',
                iv=HERE / 'params' / 'iv.txt',
                inp=HERE / 'data' / 'in.txt',
                out=HERE / 'data' / 'out.txt')


# --- text files: a byte stream written as hex, wrapped at 16 B per line -----

def read_hex(path) -> bytes:
    data = bytearray()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                data += bytes.fromhex(line)
    if not data:
        raise ValueError(f'{path}: no hex content')
    return bytes(data)


def write_hex(path, data: bytes):
    with open(path, 'w') as f:
        for i in range(0, len(data), BLOCK_BYTES):
            f.write(data[i:i + BLOCK_BYTES].hex() + '\n')


def xor(a: bytes, b: bytes) -> bytes:
    return bytes(x ^ y for x, y in zip(a, b))


# --- GCM: counter, GHASH, tag ----------------------------------------------

def inc32(block: bytes) -> bytes:
    """GCM increments only the low 32 bits; the top 96 stay put."""
    c = (int.from_bytes(block[12:], 'big') + 1) & 0xffffffff
    return block[:12] + c.to_bytes(4, 'big')


def gf_mult(x: bytes, y: bytes) -> bytes:
    """GF(2^128) product, GCM bit convention (bit 0 is the leftmost)."""
    R = 0xe1 << 120
    v = int.from_bytes(x, 'big')
    yv = int.from_bytes(y, 'big')
    z = 0
    for i in range(128):
        if (yv >> (127 - i)) & 1:
            z ^= v
        v = (v >> 1) ^ R if v & 1 else v >> 1
    return z.to_bytes(16, 'big')


def ghash(h: bytes, data: bytes) -> bytes:
    y = bytes(16)
    for i in range(0, len(data), BLOCK_BYTES):
        y = gf_mult(xor(y, data[i:i + BLOCK_BYTES]), h)
    return y


def pad16(d: bytes) -> bytes:
    """Zero-pad to a whole block. A partial AAD or CT block is padded, and the
    pad is NOT counted in the length block — that is the whole point of it."""
    return d + bytes((-len(d)) % BLOCK_BYTES)


def keystream_xor(alg, data: bytes, round_keys, j0: bytes) -> bytes:
    """CTR over the payload. Counting starts at J0+1; J0 itself masks the tag.
    The last block is truncated, never padded."""
    out = bytearray()
    ctr = inc32(j0)
    for i in range(0, len(data), BLOCK_BYTES):
        block = data[i:i + BLOCK_BYTES]
        out += xor(block, alg.encrypt_block(ctr, round_keys))
        ctr = inc32(ctr)
    return bytes(out)


def tag(alg, round_keys, j0: bytes, aad: bytes, ct: bytes) -> bytes:
    """ICV = E(J0) XOR GHASH_H( pad(A) || pad(C) || len(A)_64 || len(C)_64 ).

    The lengths are the REAL byte counts times 8, not the padded ones — this is
    what the AAD_BYTES generic feeds in the hardware."""
    h = alg.encrypt_block(bytes(16), round_keys)
    lens = (len(aad) * 8).to_bytes(8, 'big') + (len(ct) * 8).to_bytes(8, 'big')
    s = ghash(h, pad16(aad) + pad16(ct) + lens)
    return xor(alg.encrypt_block(j0, round_keys), s)[:TAG_BYTES]


# --- the packet -------------------------------------------------------------

def encrypt(alg, round_keys, j0: bytes, stream: bytes) -> bytes:
    bypass = stream[:BYPASS_BYTES]
    aad    = stream[BYPASS_BYTES:BYPASS_BYTES + AAD_BYTES]
    pt     = stream[BYPASS_BYTES + AAD_BYTES:]

    ct  = keystream_xor(alg, pt, round_keys, j0)
    icv = tag(alg, round_keys, j0, aad, ct)
    return bypass + aad + ct + icv


def decrypt(alg, round_keys, j0: bytes, stream: bytes):
    bypass = stream[:BYPASS_BYTES]
    aad    = stream[BYPASS_BYTES:BYPASS_BYTES + AAD_BYTES]
    ct     = stream[BYPASS_BYTES + AAD_BYTES:len(stream) - TAG_BYTES]
    icv    = stream[len(stream) - TAG_BYTES:]

    # The tag is computed over the RECEIVED ciphertext, before it is decrypted.
    auth_ok = (tag(alg, round_keys, j0, aad, ct) == icv)
    pt = keystream_xor(alg, ct, round_keys, j0)
    return bypass + aad + pt, auth_ok


# --- main -------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description='GCM reference model for the GCM_CRYPTO_L3_L2 chain — '
                    'the same bytes the FPGA produces, for the same key, IV and input.',
        epilog=f"""
packet layout (BYPASS_BYTES and AAD_BYTES are constants in this file,
because they are compile-time generics in the hardware)

  ENC   BYPASS({BYPASS_BYTES} B) || AAD({AAD_BYTES} B) || PT
          ->  BYPASS || AAD || CT || ICV(16 B)
  DEC   BYPASS({BYPASS_BYTES} B) || AAD({AAD_BYTES} B) || CT || ICV(16 B)
          ->  BYPASS || AAD || PT          (exit 1 if the tag does not verify)

all files are hex text: '#' comments and whitespace are ignored

examples
  ./gcm_ref.py ENC AES
  ./gcm_ref.py DEC AES --in data/ct.txt --out data/pt.txt
  ./gcm_ref.py ENC AES --key /tmp/k.txt --iv /tmp/iv.txt
""")
    ap.add_argument('operation', choices=['ENC', 'DEC'],
                    help='encrypt+authenticate, or decrypt+verify')
    ap.add_argument('algorithm', choices=list(ALGORITHMS),
                    help='the cipher: AES (AES-256)')
    ap.add_argument('--in',  dest='inp', default=DEFAULTS['inp'], metavar='FILE',
                    help='input packet   (default: data/in.txt)')
    ap.add_argument('--out', dest='out', default=DEFAULTS['out'], metavar='FILE',
                    help='output packet  (default: data/out.txt)')
    ap.add_argument('--key', default=DEFAULTS['key'], metavar='FILE',
                    help='256-bit AES key, MSB first  (default: params/key.txt)')
    ap.add_argument('--iv',  default=DEFAULTS['iv'], metavar='FILE',
                    help='J0 = 96-bit nonce || 00000001, 16 B  (default: params/iv.txt)')
    a = ap.parse_args()

    alg = importlib.import_module(ALGORITHMS[a.algorithm])
    key_bytes = alg.KEY_BITS // 8

    key = read_hex(a.key)
    if len(key) < key_bytes:
        sys.exit(f'key.txt holds {len(key)} B, {alg.NAME} needs {key_bytes} B')
    if len(key) > key_bytes:
        print(f'note: key.txt holds {len(key)} B, using the first {key_bytes} B')
        key = key[:key_bytes]

    j0 = read_hex(a.iv)
    if len(j0) != BLOCK_BYTES:
        sys.exit(f'iv.txt must hold the 16-byte J0 (nonce || 00000001), got {len(j0)} B')

    stream = read_hex(a.inp)
    least = BYPASS_BYTES + AAD_BYTES + (TAG_BYTES if a.operation == 'DEC' else 0)
    if len(stream) < least:
        sys.exit(f'input is {len(stream)} B, needs at least {least} B '
                 f'(BYPASS {BYPASS_BYTES} + AAD {AAD_BYTES}'
                 f'{f" + ICV {TAG_BYTES}" if a.operation == "DEC" else ""})')

    round_keys = alg.expand_key(key)

    print(f'{a.operation}  {alg.NAME}  '
          f'key {alg.KEY_BITS} b, {alg.NUM_ROUNDS} rounds   J0 {j0.hex()}')
    print(f'BYPASS {BYPASS_BYTES} B   AAD {AAD_BYTES} B   in {len(stream)} B')

    if a.operation == 'ENC':
        out = encrypt(alg, round_keys, j0, stream)
        print(f'ICV  {out[-TAG_BYTES:].hex()}')
    else:
        out, auth_ok = decrypt(alg, round_keys, j0, stream)
        print(f'AUTH {"OK" if auth_ok else "FAIL — the tag does not verify"}')

    write_hex(a.out, out)
    print(f'wrote {len(out)} B to {a.out}')
    if a.operation == 'DEC' and not auth_ok:
        sys.exit(1)


if __name__ == '__main__':
    main()
