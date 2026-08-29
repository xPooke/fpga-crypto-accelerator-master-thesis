# test_gf2m.py — verifies gf2m.py against an independent golden model
# (the model deliberately takes a DIFFERENT route: full carry-less product
# first, reduction at the end — so a bug in one algorithm cannot "cancel out"
# in both)
import random

from gf2m import gf_add, gf_mul, M_TEST, F_TEST, M_B571, F_B571


def golden_mul(a, b, m, f):
    prod = 0
    aa = a
    i = 0
    while aa:
        if aa & 1:
            prod ^= b << i
        aa >>= 1
        i += 1
    for deg in range(2*m - 2, m - 1, -1):
        if prod & (1 << deg):
            prod ^= f << (deg - m)
    return prod


fails = 0

# 1) results worked out by hand on paper
for a, b, exp in [(0b1011, 0b1101, 0b0110)]:
    got = gf_mul(a, b, M_TEST, F_TEST)
    print(f"paper: {a:04b}*{b:04b} = {got:04b} (expected {exp:04b})",
          "OK" if got == exp else "FAIL")
    fails += (got != exp)

# 2) exhaustively, all 256 pairs in GF(2^4)
bad = [(a, b) for a in range(16) for b in range(16)
       if gf_mul(a, b, M_TEST, F_TEST) != golden_mul(a, b, M_TEST, F_TEST)]
print(f"exhaustive GF(2^4): {256 - len(bad)}/256 OK")
fails += len(bad)

# 3) field axioms in B-571 (random pairs, fixed seed) + golden model
rng = random.Random(571)
ax_fail = 0
for _ in range(20):
    a, b, c = (rng.getrandbits(571) for _ in range(3))
    ax_fail += gf_mul(a, b, M_B571, F_B571) != gf_mul(b, a, M_B571, F_B571)
    ax_fail += gf_mul(a, gf_add(b, c), M_B571, F_B571) != gf_add(
        gf_mul(a, b, M_B571, F_B571), gf_mul(a, c, M_B571, F_B571))
    ax_fail += gf_mul(a, 1, M_B571, F_B571) != a
    ax_fail += gf_mul(a, b, M_B571, F_B571) != golden_mul(a, b, M_B571, F_B571)
print(f"B-571 axioms + golden model: {'OK' if ax_fail == 0 else str(ax_fail) + ' FAIL'}")
fails += ax_fail

print("TOTAL:", "ALL PASS" if fails == 0 else f"{fails} failures")
