# gen_ladder_vectors.py — test vectors for the ladder RTL (scalar_mult FSM + Mxy)
# from ec_ladder.py (the golden model).
# Line format: "<k> <x> <y> <b> <X1> <Z1> <X2> <Z2> <xa> <ya>"
#   k          : scalar (bit string of width m, MSB left)
#   x,y        : base point P (affine)
#   b          : curve parameter (a=1 fixed, as for the NIST B-curves)
#   X1,Z1,X2,Z2: constant-time ladder output scalar_mult_ct(k*P)
#   xa,ya      : affine k*P after Mxy (y-recovery)
# GF(2^4): exhaustively k=1..14 on the small test curve (b=1, G=(8,2), order 16).
#          k=15 is SKIPPED: P2 = 16G = O, so Z2=0 and the Mxy precondition
#          (Z2!=0) fails — x(15P)=X1/Z1 is still correct (=8), but y-recovery
#          is undefined (gf_inv(0) does not exist). The ladder FSM / TB must
#          treat the edge case k = order-1 separately.
# B-571:   DATAPATH vectors — random (k,x,y,b), seed 571. They are NOT points
#          on the NIST curve; for checking the RTL datapath that makes no
#          difference, the golden model computes the same formulas.
import random

from gf2m import gf_mul, gf_inv, M_TEST, F_TEST, M_B571, F_B571
from ec_ladder import scalar_mult, scalar_mult_ct, Mxy

import os
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", "Hardware", "ip_cores_ECDH", "ECDH", "sim")

# control table of kG on the small test curve (GF(2^4), a=b=1, G=(8,2))
KG_TABLE = {1: (0x8, 0x2), 2: (0x6, 0x7), 3: (0xa, 0x5), 4: (0x1, 0x6),
            5: (0xc, 0x8), 6: (0x7, 0x6), 7: (0xf, 0xc), 8: (0x0, 0x1),
            9: (0xf, 0x3), 10: (0x7, 0x1), 11: (0xc, 0x4), 12: (0x1, 0x7),
            13: (0xa, 0xf), 14: (0x6, 0x1), 15: (0x8, 0xa)}


def bits(x, m):
    return format(x, "0{}b".format(m))


def line(k, x, y, b, m, f):
    X1, Z1, X2, Z2 = scalar_mult_ct(k, x, y, 1, b, m, f)
    assert (X1, Z1, X2, Z2) == scalar_mult(k, x, y, 1, b, m, f)   # ct == plain
    if Z2 == 0:                     # edge case (P2 = O): Mxy undefined
        return None
    xa, ya = Mxy(X1, Z1, X2, Z2, x, y, m, f)
    return " ".join(bits(v, m) for v in (k, x, y, b, X1, Z1, X2, Z2, xa, ya)) + "\n"


def gf4_lines():
    m, f = M_TEST, F_TEST
    x, y, b = 0x8, 0x2, 1          # test curve y^2+xy = x^3+x^2+1, G=(8,2)
    out = []
    for k in range(1, 16):          # exhaustively up to the point order (16)
        ln = line(k, x, y, b, m, f)
        if ln is None:
            print("  skipped k={} (Z2=0, P2=O — Mxy undefined)".format(k))
            continue
        xa, ya = int(ln.split()[8], 2), int(ln.split()[9], 2)
        assert (xa, ya) == KG_TABLE[k], "kG table failed for k={}".format(k)
        out.append(ln)
    return out


def b571_lines():
    m, f = M_B571, F_B571
    rng = random.Random(571)
    out = []
    while len(out) < 20:
        k = rng.getrandbits(m) | (1 << (m - 1)) | 1   # full 571-bit scalar
        if not out:                                    # first vector (used by the latency
            k = (k & ~(1 << (m - 1))) | (1 << (m - 2)) # measurement): a 570-bit scalar,
                                                       # the longest standard key (< n)
        x = rng.getrandbits(m) | 1                     # x != 0 (Mxy precondition)
        y = rng.getrandbits(m)
        b = rng.getrandbits(m) | 1
        ln = line(k, x, y, b, m, f)
        if ln is not None:                             # Z2=0 practically impossible
            out.append(ln)
    return out


def b571_fixedb_lines():
    # like b571_lines but with b FIXED = 1 (the ecdh_axis_ip wrapper carries b
    # as the G_B generic, so the packet TB needs vectors with the same fixed b).
    # Seed 5710.
    m, f = M_B571, F_B571
    rng = random.Random(5710)
    b = 1
    out = []
    while len(out) < 20:
        k = rng.getrandbits(m) | (1 << (m - 1)) | 1
        x = rng.getrandbits(m) | 1
        y = rng.getrandbits(m)
        ln = line(k, x, y, b, m, f)
        if ln is not None:
            out.append(ln)
    return out


with open(os.path.join(OUT_DIR, "ladder_vec_gf4.txt"), "w") as fh:
    fh.writelines(gf4_lines())
print(os.path.join(OUT_DIR, "ladder_vec_gf4.txt") + ": k=1..14 exhaustive + kG table OK (k=15 edge, skipped)")

with open(os.path.join(OUT_DIR, "ladder_vec_b571.txt"), "w") as fh:
    fh.writelines(b571_lines())
print(os.path.join(OUT_DIR, "ladder_vec_b571.txt") + ": 20 random datapath vectors (seed 571)")

with open(os.path.join(OUT_DIR, "ladder_vec_b571_fixedb.txt"), "w") as fh:
    fh.writelines(b571_fixedb_lines())
print(os.path.join(OUT_DIR, "ladder_vec_b571_fixedb.txt") + ": 20 vectors, b FIXED=1 (for ecdh_axis_ip)")
