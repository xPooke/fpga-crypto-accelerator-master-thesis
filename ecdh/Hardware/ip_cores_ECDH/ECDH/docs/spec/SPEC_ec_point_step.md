# SPEC: `ec_point_step` — jedan korak Montgomery lestvice (madd + mdouble)

**Fajl:** `src/ec_point_step.vhd` · **Sloj:** EC (klijent `gf_alu`) · **Teorija:** `FORMULE_EC.md` §7, `Rad_cswap_ladder.md`

## Namena

Izvrši FIKSNI korak constant-time lestvice iz tvog `scalar_mult_ct`
(`ec_ladder.py`), za ulaze koji su VEĆ prošli cswap:

```
(nX2, nZ2) = madd(X2, Z2, X1, Z1, xb)     -- P2 = P1 + P2
(nX1, nZ1) = mdouble(X1, Z1, b)           -- P1 = 2*P1
```

Modul je **ALU-klijent**: ne instancira nijedan aritmetički blok, nego izdaje
operacije jednoj deljenoj `gf_alu` preko handshake-a — isti obrazac kao što je
`gf_inv` mul-klijent (vidi `gf_inv.vhd` portove `o_mul_*` / `i_mul_*`).
Osnovna varijanta: striktno sekvencijalno, jedna operacija u letu.

## Interfejs

Generik: `G_M : integer := 4`.

| Port | Smer | Tip | Opis |
|---|---|---|---|
| `i_clk`, `i_resetn` | in | `std_logic` | takt, sinhroni aktivno-nizak reset |
| `i_start` | in | `std_logic` | 1-takt strob: uhvati ulaze, kreni |
| `i_x1, i_z1` | in | `slv(G_M-1:0)` | P1 (posle cswap-a) |
| `i_x2, i_z2` | in | `slv(G_M-1:0)` | P2 (posle cswap-a) |
| `i_xb` | in | `slv(G_M-1:0)` | x bazne tačke P (madd-u treba razlika P2−P1 = P) |
| `i_b` | in | `slv(G_M-1:0)` | parametar krive b (u Fazi 2 postaje konstanta/XOR mreža) |
| `o_x1, o_z1` | out | `slv(G_M-1:0)` | nova P1 = 2·P1 |
| `o_x2, o_z2` | out | `slv(G_M-1:0)` | nova P2 = P1+P2 |
| `o_busy` | out | `std_logic` | 1 dok korak traje |
| `o_done` | out | `std_logic` | 1-takt puls: rezultati važe |
| **ALU-klijent:** | | | |
| `o_alu_start` | out | `std_logic` | 1-takt strob ka ALU, gejtovan na `i_alu_busy='0'` |
| `o_alu_op` | out | `alu_op_t` | ALU_ADD / ALU_SQR / ALU_MUL (INV se ovde NE koristi) |
| `o_alu_a, o_alu_b` | out | `slv(G_M-1:0)` | operandi (SQR koristi samo a) |
| `i_alu_busy` | in | `std_logic` | ALU zauzet |
| `i_alu_done` | in | `std_logic` | 1-takt puls: `i_alu_res` važi |
| `i_alu_res` | in | `slv(G_M-1:0)` | rezultat operacije |

## Redosled operacija (mikroprogram — 14 ALU poziva)

Scratch registri: `r_t1, r_t2, r_t3` (+ registrovani ulazi `r_x1, r_z1, r_x2,
r_z2, r_xb, r_b` i izlazi `r_nx1, r_nz1, r_nx2, r_nz2`). Redosled 1:1 prati
tvoje Python funkcije; madd i mdouble čitaju SAMO registrovane ulaze, pišu u
`r_n*` — pa nema hazarda i redosled madd/mdouble je zapravo slobodan.

| # | Op | a | b | odredište | komentar |
|---|-----|------|------|-----------|----------|
| — | *madd(X2,Z2,X1,Z1,xb):* | | | | `T1=X1'·Z2'` gde je (X1',Z1')=(X2,Z2) |
| 1 | MUL | r_x2 | r_z1 | r_t1 | T1 = X2·Z1 |
| 2 | MUL | r_x1 | r_z2 | r_t2 | T2 = X1·Z2 |
| 3 | ADD | r_t1 | r_t2 | r_t3 | T1+T2 |
| 4 | SQR | r_t3 | — | r_nz2 | **nZ2** = (T1+T2)² |
| 5 | MUL | r_t1 | r_t2 | r_t3 | T1·T2 |
| 6 | MUL | r_xb | r_nz2 | r_t1 | xb·nZ2 |
| 7 | ADD | r_t1 | r_t3 | r_nx2 | **nX2** = xb·nZ2 + T1·T2 |
| — | *mdouble(X1,Z1,b):* | | | | |
| 8 | SQR | r_x1 | — | r_t1 | X1² |
| 9 | SQR | r_z1 | — | r_t2 | Z1² |
| 10 | MUL | r_t1 | r_t2 | r_nz1 | **nZ1** = X1²·Z1² |
| 11 | SQR | r_t1 | — | r_t1 | X1⁴ |
| 12 | SQR | r_t2 | — | r_t2 | Z1⁴ |
| 13 | MUL | r_b | r_t2 | r_t2 | b·Z1⁴ |
| 14 | ADD | r_t1 | r_t2 | r_nx1 | **nX1** = X1⁴ + b·Z1⁴ |

Bilans: **6 MUL + 5 SQR + 3 ADD** — tačno "≈6 množenja po bitu" iz plana.
(ADD/SQR kroz ALU koštaju ~3 takta handshake-a; lokalni XOR umesto ALU_ADD je
moguća optimizacija — osnovno jezgro sve tera kroz ALU, a paralelni korak ADD/SQR radi lokalno.)

## FSM — dve opcije (biraš ti)

1. **Mikroprogram (preporuka):** brojač `r_pc` 1..14 + konstantna tabela
   `(op, sel_a, sel_b, sel_dst)`; stanja samo `S_IDLE / S_ISSUE / S_WAIT /
   S_DONE`. Manje kucanja, lako se prošire koraci u Fazi 2.
2. **Eksplicitna stanja:** `S_MADD_T1, S_MADD_T2, ...` — čitljivije u
   dijagramu, ali 14×2 stanja.

Handshake pravila (ista kao u `gf_inv`/`gf_alu`):
- `o_alu_start` sme biti '1' tačno 1 takt i SAMO kad je `i_alu_busy='0'`
  (flag `r_launched` po operaciji, kao `r_mul_launched` u `gf_inv.vhd`).
- Rezultat se hvata na `i_alu_done='1'`, pa prelaz na sledeću operaciju.

## Rubni slučajevi

- Ako je P2 = O (Z2=0), formule daju degenerisan rezultat — to se dešava samo
  za k = red−1 (vidi `gen_ladder_vectors.py` napomenu za k=15 u GF(2⁴)).
  `ec_point_step` NE proverava ovo — odgovornost višeg sloja / protokola.
- INV se u koraku ne koristi; jedina inverzija je u Mxy modulu na kraju.

## Verifikacija

- TB `tb_ec_point_step_vec.vhd`: instancira `ec_point_step` + `gf_alu`, spaja
  klijent portove (kao što `tb_gf_inv_vec` spaja gf_inv+gf_mul).
- Vektori: `gen_step_vectors.py` → `sim/step_vec_{gf4,b571}.txt`
  (format: `x1 z1 x2 z2 xb b nx1 nz1 nx2 nz2`), referenca su tvoji
  `madd`/`mdouble` iz `ec_ladder.py`.
- End-to-end (kasnije, sa scalar-mult FSM-om): `sim/ladder_vec_{gf4,b571}.txt`.
