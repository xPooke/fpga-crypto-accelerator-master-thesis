# SPEC: `ec_point_step_par` — paralelni korak Montgomery lestvice

**Fajl:** `src/ec_point_step_par.vhd` · **Sloj:** EC (vlasnik množača) ·
**Teorija:** x-only korak Montgomeryjevih merdevina (poglavlje 3 rada) ·
**Poređenje:** `SPEC_ec_point_step.md` (isti zlatni model, ista formula, drugi
model izvršavanja)

## Namena

Izvrši ISTI fiksni korak lestvice kao `ec_point_step` (posle cswap-a):
```
(nX2, nZ2) = madd(X2, Z2, X1, Z1, xb)     -- P2 = P1 + P2
(nX1, nZ1) = mdouble(X1, Z1, b)           -- P1 = 2*P1
```
ali **za minimalnu latenciju**: umesto 14 poziva jednom deljenom `gf_alu`, modul
**poseduje 3 `gf_mul`** i izvršava 6 množenja u **2 paralelne runde**; sve SQR/ADD
su lokalne kombinacione mreže (`gf_sqr` + `xor`). Rezultat je **bit-identičan**
Fazi 1 (isti vektori `step_vec_*.txt`).

## Interfejs

Generici: `G_M`, `G_D` (digit širina množača), `G_F` (redukcioni polinom,
G_M+1 bita). **Nema ALU-klijent magistrale** (korak je vlasnik množača).

| Port | Smer | Opis |
|---|---|---|
| `i_clk`, `i_resetn` | in | takt, sinhroni aktivno-nizak reset |
| `i_start` | in | 1-takt strob |
| `i_x1,i_z1,i_x2,i_z2` | in | P1, P2 (posle cswap-a) |
| `i_xb` | in | x bazne tačke P |
| `i_b` | in | parametar krive b (**runtime**, ne generik) |
| `o_x1,o_z1` | out | nP1 = 2·P1 |
| `o_x2,o_z2` | out | nP2 = P1+P2 |
| `o_busy`, `o_done` | out | status; `o_done` 1-takt puls |

## Raspored (2 runde, dubina zavisnosti = 2)

| Runda | traka 0 | traka 1 | traka 2 |
|---|---|---|---|
| **R1** | `M1 = X2·Z1` | `M2 = X1·Z2` | `M10 = X1²·Z1²` |
| **R2** | `M5 = T1·T2` | `M6 = xb·nZ2` | `M13 = b·Z1⁴` |

Lokalno (kombinaciono, 0 taktova): `nZ1=M10`, `nX1=X1⁴+b·Z1⁴`,
`nZ2=(M1+M2)²`, `nX2=M5+M6`. Kvadrati `X1²,X1⁴,Z1²,Z1⁴,(M1+M2)²` su 5×`gf_sqr`.

**Zašto 3 množača:** M5,M6 zavise od M1,M2 → dubina 2 → 2 runde je dno.
R1 ima 3 nezavisna posla, R2 ima 3 (M13 nezavisan od početka, puni 3. traku).
4. množač bi dangubio. To je algoritamski limit paralelizma LD koraka.

## FSM

`S_IDLE → S_R1_ISSUE → S_R1_WAIT → S_R2_ISSUE → S_R2_WAIT → S_DONE`. Sva 3
množača startuju zajedno (identična latencija `⌈m/D⌉`), pa se čeka `AND` njihovih
`done`. Start je 1-takt strob (ISSUE stanja traju 1 takt dok množači sede u
S_IDLE/S_DONE load stanju).

## Latencija

`~2·⌈m/D⌉ + režija` taktova/korak (B-571 D=32: ~43) vs `~6·⌈m/D⌉ + handshake`
u Fazi 1 (~172). **~4× po koraku.** D ostaje knoba površina/propusnost; latenciju
množača ne menja (A5 sinteza meri f_max(D)).

## Odluke dizajna (razlike od plana)

- **`b` runtime, ne generik.** `b·Z1⁴` (M13) puni inače praznu 3. traku R2, pa
  const-b XOR mreža (A1) ne štedi rundu → izbačena (latencijski neutralna). Bonus:
  modul se testira na postojećim random-`b` `step_vec` vektorima.
- **SQR/ADD lokalni** (A2) — bez handshake-a; ovde se meri „cena uniformnosti" Faze 1.

## Verifikacija

`sim/tb_ec_point_step_par_vec.vhd` (isti format i zlatni model kao za osnovno jezgro):
GF(2⁴) **503 PASS**; B-571 D=1/8/32 **20 PASS** svaki. Rezultat bit-identičan
`ec_point_step`.
