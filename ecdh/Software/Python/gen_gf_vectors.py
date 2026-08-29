# gen_gf_vectors.py — generates test vectors for tb_gf_mul_vec.vhd from gf2m.py.
# Line format: "<a> <b> <exp>", each as a bit string of width m (MSB left).
# Bit strings (not hex) because m=571 is not divisible by 4 -> no nibble alignment.
import random

from gf2m import gf_mul, M_TEST, F_TEST, M_B571, F_B571

import os
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", "Hardware", "ip_cores_ECDH", "ECDH", "sim")


def bits(x, m):
    return format(x, "0{}b".format(m))


def write_vectors(path, pairs, m, f):
    with open(path, "w") as fh:
        for a, b in pairs:
            fh.write("{} {} {}\n".format(bits(a, m), bits(b, m),
                                         bits(gf_mul(a, b, m, f), m)))
    print("{}: {} vectors (m={})".format(path, len(pairs), m))


# 1) GF(2^4): exhaustively, all 16*16 = 256 pairs
pairs4 = [(a, b) for a in range(16) for b in range(16)]
write_vectors(os.path.join(OUT_DIR, "gf_vec_gf4.txt"), pairs4, M_TEST, F_TEST)

# 2) B-571: edge cases + 300 random (fixed seed = reproducible)
rng = random.Random(571)
edge = [(0, 0), (0, 1), (1, 1), (1, 2),
        ((1 << M_B571) - 1, 1),                 # all-ones * 1
        ((1 << M_B571) - 1, (1 << M_B571) - 1)] # all-ones * all-ones
rand = [(rng.getrandbits(M_B571), rng.getrandbits(M_B571)) for _ in range(300)]
write_vectors(os.path.join(OUT_DIR, "gf_vec_b571.txt"), edge + rand, M_B571, F_B571)
