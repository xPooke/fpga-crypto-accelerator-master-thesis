"""
gf_sqr_depth.py — combinational depth analysis of the GF(2^m) squarer.

Squaring is a fixed linear map y = M*a over GF(2):
  - bit spreading (bit i -> position 2i) is pure wiring (zero logic),
  - reduction by the irreducible polynomial f is a fixed XOR network.
The depth comes ONLY from the reduction: how many input bits XOR into one
output bit (= the fan-in of the XOR tree). From there:
  - depth of a 2-input XOR tree = ceil(log2(max_fan_in)),
  - depth on Xilinx LUT6        = ceil(log6(max_fan_in)).

The polynomial f is given as a set of exponents, e.g. the B-571 pentanomial
  f(x) = x^571 + x^10 + x^5 + x^2 + 1  ->  {571, 10, 5, 2, 0}.
"""
import math


def reduce_mono(e: int, m: int, F: set) -> set:
    """x^e mod f, as a set of output exponents (< m). F = exponents of f."""
    low = sorted(t for t in F if t != m)      # f without the leading x^m
    s = {e}
    while True:
        hi = max(s)
        if hi < m:
            break
        # x^hi = x^(hi-m) * (x^m) ≡ x^(hi-m) * (sum of the lower terms of f)
        s.remove(hi)
        for t in low:
            e2 = hi - m + t
            s ^= {e2}                          # XOR (mod 2): toggle the term
    return s


def sqr_xor_depth(m: int, F: set):
    """Return (max_fan_in, distribution, xor2_depth, lut6_depth) for the squarer."""
    counts = [0] * m                           # fan-in of every output bit
    for i in range(m):
        for k in reduce_mono(2 * i, m, F):     # where input bit a_i contributes
            counts[k] += 1
    max_fan = max(counts)
    dist = {v: counts.count(v) for v in sorted(set(counts))}
    depth_xor2 = math.ceil(math.log2(max_fan)) if max_fan > 1 else 0
    depth_lut6 = math.ceil(math.log(max_fan, 6)) if max_fan > 1 else 0
    return max_fan, dist, depth_xor2, depth_lut6


if __name__ == "__main__":
    fields = {
        "GF(2^4)  f=x^4+x+1":           (4,   {4, 1, 0}),
        "B-571    pentanomial":         (571, {571, 10, 5, 2, 0}),
    }
    for name, (m, F) in fields.items():
        mf, dist, d2, d6 = sqr_xor_depth(m, F)
        print(f"{name}")
        print(f"  max XOR fan-in   = {mf}")
        print(f"  fan-in distribution = {dist}")
        print(f"  2-input XOR depth  = {d2} levels")
        print(f"  LUT6 depth         = {d6} LUT level(s)\n")
