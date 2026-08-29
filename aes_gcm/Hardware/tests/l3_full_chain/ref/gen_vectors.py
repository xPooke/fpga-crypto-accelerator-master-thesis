#!/usr/bin/env python3
"""
Company  : University of Belgrade, School of Electrical Engineering (ETF)
Engineer : Marko Gavrilović
Email    : markog0403@gmail.com

Golden-vector generator for the GCM stack.

Produces the reference ciphertext and tag for one (AAD_BYTES, PT_BYTES) pair with
a software AES-128-GCM implementation, so tb_gcm_kat_len can compare against it.
Sweeping every AAD / PT residue mod 16 is what proves the partial-block
(zero-padding) path is standard compliant, not merely self-consistent.

Key and IV are fixed and match the testbench:
    K  = feffe9928665731c6d6a8f9467308308
    IV = cafebabefacedbaddecaf888          (96-bit nonce)
The packet is a 16-byte bypass header followed by AAD and PT, both filled with
the deterministic pattern (i*7 + 13) mod 256.

Usage: gen_vectors.py <AAD_BYTES> <PT_BYTES> <out_file>
Writes two hex lines: the ciphertext, then the tag.
"""
import sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

HDR = 16
KEY = bytes.fromhex("feffe9928665731c6d6a8f9467308308")
IV  = bytes.fromhex("cafebabefacedbaddecaf888")          # 96-bit -> J0 = IV || 00000001


def pattern(i: int) -> int:
    return (i * 7 + 13) % 256


def main() -> None:
    aad_len = int(sys.argv[1])
    pt_len  = int(sys.argv[2])
    out     = sys.argv[3]

    aad = bytes(pattern(HDR + i) for i in range(aad_len))
    pt  = bytes(pattern(HDR + aad_len + i) for i in range(pt_len))

    blob = AESGCM(KEY).encrypt(IV, pt, aad)     # ciphertext || tag
    ct, tag = blob[:pt_len], blob[pt_len:]

    with open(out, "w") as f:
        f.write(ct.hex() + "\n")
        f.write(tag.hex() + "\n")


if __name__ == "__main__":
    main()
