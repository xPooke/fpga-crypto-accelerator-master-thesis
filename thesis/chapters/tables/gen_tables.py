#!/usr/bin/env python3
"""Generates the LaTeX tables: AES S-box, Rcon, Keccak rotation offsets and RC constants."""
import os

OUT = os.path.dirname(os.path.abspath(__file__))

# ---------- AES S-box ----------
def gmul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p

inv = {0: 0}
for x in range(1, 256):
    for y in range(1, 256):
        if gmul(x, y) == 1:
            inv[x] = y
            break

def affine(b):
    def rot(v, n):
        return ((v << n) | (v >> (8 - n))) & 0xFF
    return b ^ rot(b, 1) ^ rot(b, 2) ^ rot(b, 3) ^ rot(b, 4) ^ 0x63

sbox = [affine(inv[x]) for x in range(256)]
assert sbox[0x53] == 0xED and sbox[0x00] == 0x63 and sbox[0x01] == 0x7C, "S-box check failed!"

rows = []
header = " & ".join(["\\cellcolor{gray!30}"] + [f"\\cellcolor{{gray!30}}\\texttt{{{c:X}}}" for c in range(16)])
rows.append(header + " \\\\ \\hline")
for r in range(16):
    cells = [f"\\cellcolor{{gray!30}}\\texttt{{{r:X}}}"] + [f"\\texttt{{{sbox[16*r+c]:02X}}}" for c in range(16)]
    rows.append(" & ".join(cells) + " \\\\ \\hline")

with open(f"{OUT}/sbox.tex", "w") as f:
    f.write("% Automatski generisano skriptom gen_tables.py -- AES S-box (FIPS 197)\n")
    f.write("\\begin{tabular}{|c|" + "c|" * 16 + "}\n\\hline\n")
    f.write("\n".join(rows))
    f.write("\n\\end{tabular}\n")

# ---------- Rcon ----------
rcon = []
rc = 1
for i in range(10):
    rcon.append(rc)
    rc = gmul(rc, 2)
with open(f"{OUT}/rcon.tex", "w") as f:
    f.write("% Automatski generisano -- Rcon konstante\n")
    f.write("\\begin{tabular}{|c|" + "c|" * 10 + "}\n\\hline\n")
    f.write("\\cellcolor{gray!30}$i$ & " + " & ".join(f"\\cellcolor{{gray!30}}{i+1}" for i in range(10)) + " \\\\ \\hline\n")
    f.write("\\cellcolor{gray!30}$Rcon_i$ & " + " & ".join(f"\\texttt{{{v:02X}}}" for v in rcon) + " \\\\ \\hline\n")
    f.write("\\end{tabular}\n")

# ---------- Keccak rotation offsets ----------
r = [[0] * 5 for _ in range(5)]
x, y = 1, 0
for t in range(24):
    r[x][y] = ((t + 1) * (t + 2) // 2) % 64
    x, y = y, (2 * x + 3 * y) % 5
# poznate vrednosti za proveru
assert r[1][0] == 1 and r[0][0] == 0 and r[2][2] == 43, "Keccak offsets are wrong!"

with open(f"{OUT}/keccak_offsets.tex", "w") as f:
    f.write("% Automatski generisano -- Keccak-f[1600] rotacioni ofseti r[x][y]\n")
    f.write("\\begin{tabular}{|c|c|c|c|c|c|}\n\\hline\n")
    f.write("\\cellcolor{gray!30} & " + " & ".join(f"\\cellcolor{{gray!30}}$x={i}$" for i in range(5)) + " \\\\ \\hline\n")
    for yy in range(5):
        f.write(f"\\cellcolor{{gray!30}}$y={yy}$ & " + " & ".join(str(r[xx][yy]) for xx in range(5)) + " \\\\ \\hline\n")
    f.write("\\end{tabular}\n")

# ---------- Keccak RC constants ----------
def rc_bit(t):
    if t % 255 == 0:
        return 1
    R = 1
    for _ in range(1, t % 255 + 1):
        R <<= 1
        if R & 0x100:
            R ^= 0x171
    return R & 1

RC = []
for i in range(24):
    v = 0
    for j in range(7):
        if rc_bit(7 * i + j):
            v |= 1 << (2 ** j - 1)
    RC.append(v)
assert RC[0] == 0x1 and RC[1] == 0x8082 and RC[23] == 0x8000000080008008, "RC constants are wrong!"

with open(f"{OUT}/keccak_rc.tex", "w") as f:
    f.write("% Automatski generisano -- Keccak-f[1600] konstante rundi RC_i\n")
    f.write("\\begin{tabular}{|c|c||c|c|}\n\\hline\n")
    f.write("\\cellcolor{gray!30}$i$ & \\cellcolor{gray!30}$RC_i$ & \\cellcolor{gray!30}$i$ & \\cellcolor{gray!30}$RC_i$ \\\\ \\hline\n")
    for i in range(12):
        f.write(f"{i} & \\texttt{{{RC[i]:016X}}} & {i+12} & \\texttt{{{RC[i+12]:016X}}} \\\\ \\hline\n")
    f.write("\\end{tabular}\n")

print("OK: all tables generated and checked.")
