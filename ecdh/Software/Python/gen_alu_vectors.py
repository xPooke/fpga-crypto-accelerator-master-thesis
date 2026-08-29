# gen_alu_vectors.py — test vectors for tb_gf_alu_vec.vhd from gf2m.py (golden model).
# Line format: "<op> <a> <b> <exp>"
#   op: 0=ADD, 1=SQR, 2=MUL, 3=INV   (SQR/INV do not use b -> zeros)
#   a,b,exp: bit strings of width m (MSB left)
import random

from gf2m import (gf_add, gf_sqr, gf_mul, gf_inv,
                  M_TEST, F_TEST, M_B571, F_B571)

import os
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", "Hardware", "ip_cores_ECDH", "ECDH", "sim")


def bits(x, m):
    return format(x, "0{}b".format(m))


def line(op, a, b, exp, m):
    return "{} {} {} {}\n".format(op, bits(a, m), bits(b, m), bits(exp, m))


def gf4_lines():
    m, f = M_TEST, F_TEST
    out = []
    for a in range(16):
        for b in range(16):
            out.append(line(0, a, b, gf_add(a, b), m))        # ADD exhaustive
            out.append(line(2, a, b, gf_mul(a, b, m, f), m))  # MUL exhaustive
    for a in range(16):
        out.append(line(1, a, 0, gf_sqr(a, m, f), m))         # SQR exhaustive
    for a in range(1, 16):
        out.append(line(3, a, 0, gf_inv(a, m, f), m))         # INV exhaustive (a!=0)
    return out


def b571_lines():
    m, f = M_B571, F_B571
    rng = random.Random(571)
    out = []
    samples = [1, 2, 3, (1 << 570), (1 << m) - 1, (1 << 285) | 7]
    rnd = [rng.getrandbits(m) | 1 for _ in range(12)]
    for a in samples + rnd:
        b = rng.getrandbits(m)
        out.append(line(0, a, b, gf_add(a, b), m))
        out.append(line(1, a, 0, gf_sqr(a, m, f), m))
        out.append(line(2, a, b, gf_mul(a, b, m, f), m))
        out.append(line(3, a, 0, gf_inv(a, m, f), m))         # a!=0 (samples/rnd are !=0)
    return out


with open(os.path.join(OUT_DIR, "alu_vec_gf4.txt"), "w") as fh:
    fh.writelines(gf4_lines())
print(os.path.join(OUT_DIR, "alu_vec_gf4.txt") + ": ADD+MUL 256 + SQR 16 + INV 15")

with open(os.path.join(OUT_DIR, "alu_vec_b571.txt"), "w") as fh:
    fh.writelines(b571_lines())
print(os.path.join(OUT_DIR, "alu_vec_b571.txt") + ": 18 values x 4 operations")
