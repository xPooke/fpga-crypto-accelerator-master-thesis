#!/usr/bin/env python3
# ---------------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Create Date   : August 2026
# Design Name   : gen_kat_vectors
# Tool Version  : Python 3 (hashlib)
#
# Description   : Regenerates every known-answer vector file the KAT testbenches
#                 read, from the hashlib reference implementation. The messages
#                 are not stored in the files -- each testbench rebuilds them
#                 from the same deterministic patterns coded below:
#
#                   tb_shake_kat      4 messages: "abc" (3 B), 200 x 0xA3,
#                                     rate bytes of 0,1,2,..., rate-1 bytes of
#                                     the same pattern. One digest per line.
#                   tb_sha3_len_sweep messages of length 1..160 with the byte
#                                     pattern 0,1,2,...  One digest per line.
#                   tb_sha3_overlap   2 messages of 1360 B (10 SHAKE256 rate
#                                     blocks): pattern 0,1,2,... and all-0xA3.
#
#                 The cSHAKE/KMAC vectors come from gen_cshake_vectors.py, not
#                 from here. Running this script must reproduce the committed
#                 files byte for byte.
# ---------------------------------------------------------------------------------
import hashlib
from pathlib import Path

SIM = Path(__file__).resolve().parent

RATE = {"shake_128": 168, "shake_256": 136}


def pattern(n):
    return bytes(i % 256 for i in range(n))


def write(fname, lines):
    (SIM / fname).write_text("".join(line + "\n" for line in lines))
    print(f"wrote {fname} ({len(lines)} digests)")


# --- tb_shake_kat: 4 messages per (variant, out_bits) file ---------------------
for var, out_bits_list in (("shake_128", (512, 4096)), ("shake_256", (1024, 8192))):
    rate = RATE[var]
    msgs = [b"abc", b"\xa3" * 200, pattern(rate), pattern(rate - 1)]
    for out_bits in out_bits_list:
        digests = [getattr(hashlib, var)(m).hexdigest(out_bits // 8) for m in msgs]
        write(f"{var.replace('_', '')}_kat_{out_bits}.txt", digests)

# --- tb_sha3_len_sweep: lengths 1..160, pattern 0,1,2,... ----------------------
for fname, algo, out_bits in (("len_sweep_sha3_256.txt", "sha3_256", 256),
                              ("len_sweep_shake256_1024.txt", "shake_256", 1024),
                              ("len_sweep_shake128_4096.txt", "shake_128", 4096)):
    lines = []
    for ln in range(1, 161):
        h = getattr(hashlib, algo)(pattern(ln))
        lines.append(h.hexdigest(out_bits // 8) if algo.startswith("shake_")
                     else h.hexdigest())
    write(fname, lines)

# --- tb_sha3_overlap: 2 messages of 1360 B, SHAKE256/8192 ----------------------
write("overlap_shake256_8192.txt",
      [hashlib.shake_256(pattern(1360)).hexdigest(1024),
       hashlib.shake_256(b"\xa3" * 1360).hexdigest(1024)])
