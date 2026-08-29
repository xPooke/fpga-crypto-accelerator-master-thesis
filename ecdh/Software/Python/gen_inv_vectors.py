# gen_inv_vectors.py — test vectors for tb_gf_inv_vec.vhd from gf2m.py (golden model).
# Line format: "<a> <exp>", both as bit strings of width m (MSB left). a != 0.
import random

from gf2m import gf_inv, M_TEST, F_TEST, M_B571, F_B571

import os
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", "Hardware", "ip_cores_ECDH", "ECDH", "sim")


def bits(x, m):
    return format(x, "0{}b".format(m))


def write_vectors(path, vals, m, f):
    with open(path, "w") as fh:
        for a in vals:
            fh.write("{} {}\n".format(bits(a, m), bits(gf_inv(a, m, f), m)))
    print("{}: {} vectors (m={})".format(path, len(vals), m))


# 1) GF(2^4): exhaustively, all a != 0  (15)
write_vectors(os.path.join(OUT_DIR, "inv_vec_gf4.txt"), range(1, 16), M_TEST, F_TEST)

# 2) B-571: edge cases + 30 random (fixed seed = reproducible)
rng = random.Random(571)
edge = [1, 2, 3, (1 << M_B571) - 1, (1 << 570), (1 << 285) | 7]
rand = [rng.getrandbits(M_B571) | 1 for _ in range(30)]   # | 1 guarantees != 0
write_vectors(os.path.join(OUT_DIR, "inv_vec_b571.txt"), edge + rand, M_B571, F_B571)
