# gen_step_vectors.py — test vectors for ec_point_step.vhd (one ladder step)
# from ec_ladder.py (golden model functions madd/mdouble).
# The step is the FIXED part of scalar_mult_ct (inputs already went through cswap):
#   (nX2,nZ2) = madd(X2,Z2,X1,Z1,xb) ;  (nX1,nZ1) = mdouble(X1,Z1,b)
# Line format: "<x1> <z1> <x2> <z2> <xb> <b> <nx1> <nz1> <nx2> <nz2>"
#   (bit strings of width m, MSB left)
# GF(2^4): 500 random + edge cases (0/1/all-ones), seed 44.
# B-571:   20 random, seed 571. As for the field level: datapath vectors, they
#          need not be points on the curve — the RTL computes the same formulas
#          as the golden model.
import random

from gf2m import M_TEST, F_TEST, M_B571, F_B571
from ec_ladder import madd, mdouble

import os
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", "Hardware", "ip_cores_ECDH", "ECDH", "sim")


def bits(x, m):
    return format(x, "0{}b".format(m))


def line(x1, z1, x2, z2, xb, b, m, f):
    nx2, nz2 = madd(x2, z2, x1, z1, xb, m, f)
    nx1, nz1 = mdouble(x1, z1, b, m, f)
    vals = (x1, z1, x2, z2, xb, b, nx1, nz1, nx2, nz2)
    return " ".join(bits(v, m) for v in vals) + "\n"


def gf4_lines():
    m, f = M_TEST, F_TEST
    rng = random.Random(44)
    out = []
    edges = [(0x8, 1, 0xe, 0xc, 0x8, 1),      # first step on the small test curve (G=(8,2))
             (0, 0, 0, 0, 0, 0),              # all zeros
             (0xf, 0xf, 0xf, 0xf, 0xf, 0xf)]  # all ones
    for e in edges:
        out.append(line(*e, m, f))
    for _ in range(500):
        vals = [rng.getrandbits(m) for _ in range(6)]
        out.append(line(*vals, m, f))
    return out


def b571_lines():
    m, f = M_B571, F_B571
    rng = random.Random(571)
    out = []
    for _ in range(20):
        vals = [rng.getrandbits(m) for _ in range(6)]
        out.append(line(*vals, m, f))
    return out


with open(os.path.join(OUT_DIR, "step_vec_gf4.txt"), "w") as fh:
    fh.writelines(gf4_lines())
print(os.path.join(OUT_DIR, "step_vec_gf4.txt") + ": 3 edge + 500 random (seed 44)")

with open(os.path.join(OUT_DIR, "step_vec_b571.txt"), "w") as fh:
    fh.writelines(b571_lines())
print(os.path.join(OUT_DIR, "step_vec_b571.txt") + ": 20 random (seed 571)")
