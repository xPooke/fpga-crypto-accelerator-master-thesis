# ec_scalar_mult — Montgomery lestvica (x-only, projektivno)

**RTL:** `src/ec_scalar_mult.vhd` · **Slika:** `ec_scalar_mult.svg` ·
**Spec:** `../spec/SPEC_ec_scalar_mult.md` · **Teorija:** `Ucenje_ECDH.md`, Lekcija 5
· **Verifikacija:** `tb_ec_scalar_mult_vec` (ALU spolja, kao u ecdh_top):
GF(2⁴) **ALL 14 PASS** (k=1..14, uklj. rub k=1); B-571 **ALL 20 PASS** (D=8, D=32)

## Posao (tri rečenice)

1. Iz `(k, xb, b)` računa projektivno stanje `(X1,Z1,X2,Z2)` gde je
   `x(k·P) = X1/Z1` — bez ijedne inverzije (nju radi `ec_mxy` posle).
2. „Dirigent": instancira `ec_cswap` (komb.) i `ec_point_step` (ALU-klijent) i
   sam ne računa ništa u polju; po bitu skalara: **swap → point_step → reswap**.
3. Sam je **ALU-klijent** — ne poseduje `gf_alu` (živi u `ecdh_top`); step-ova
   ALU magistrala prolazi kroz portove ovog modula.

## Invarijanta lestvice

Kroz celu petlju: `P1 = j·P`, `P2 = (j+1)·P`, gde je `j` pročitani prefiks
skalara (novi bit b: `j ⇐ 2j+b`). Korak pravi novi par `(2j, 2j+1)·P` —
mdouble = tangenta, madd = sečica; bit=1 slučaj su iste dve operacije sa
zamenjenim ulogama, što rešava cswap (zato swap pre i reswap posle koraka).
Na kraju `j = k` → `P1 = k·P`.

## Interfejs

Generik: `G_M`. Portovi: standard (`i_clk/i_resetn/i_start`), ulazi
`i_k` (k ≥ 1), `i_xb`, `i_b`; izlazi `o_x1/o_z1/o_x2/o_z2`, `o_busy/o_done`;
+ 7-portna ALU-klijent magistrala (`o_alu_start/op/a/b`, `i_alu_busy/done/res`).

## Mašina stanja

| Stanje | Šta radi | Izlaz |
|---|---|---|
| `S_IDLE` | snapshot; init P1=P2=(xb,1); `r_cnt ⇐ G_M` | start → `S_ALIGN` |
| `S_ALIGN` | HW `bin(k)[3:]`: šift vodećih nula + MSB-a iz `r_k` | MSB=1 → `S_INIT_2P`; `r_cnt=0` → `S_DONE` (defanzivno k=0) |
| `S_INIT_2P` | init trik: step sa P1=P2, upis SAMO nP1=2P u P2 | done → `S_SWAP` (ili `S_DONE` za k=1) |
| `S_SWAP` | upis cswap izlaza (1 takt) | → `S_POINT_STEP` |
| `S_POINT_STEP` | vozi step, na done upis sva 4 registra | → `S_RESWAP` |
| `S_RESWAP` | ista zamena nazad (w_bit se nije mrdnuo) | → `S_NEXT_BIT` |
| `S_NEXT_BIT` | potroši bit: šift `r_k`, `r_cnt−1` | `r_cnt=1` → `S_DONE`, inače → `S_SWAP` |
| `S_DONE` | done puls, registri miruju | → `S_IDLE` |

## Ključni dizajni

- **`r_k` je šift-registar**: tekući bit = UVEK ista žica (`r_k(G_M-1)`), bez
  G_M:1 muxa i prioritetnog kodera — trampa ≤G_M taktova ALIGN-a (0,2% vremena)
  za stotine LUT-ova.
- **Init trik**: 2P se dobija puštanjem step-a sa P1=P2=(xb,1) (2:1 mux na
  x2/z2 ulazu step-a); nP1 = mdouble(P) = 2P se upiše, nP2 (đubre, prekršen
  madd preduslov) prosto nema write-enable.
- **Constant-time po bitu**: cswap je mask/mux bez grananja; upisi se dešavaju
  uvek, i za bit=0 (iste vrednosti). Ukupno vreme ipak otkriva bitlen(k) —
  prihvatljivo za ECDH sa slučajnim k (~2 bita), beleška u SPEC-u.

## Cena (B-571)

Po bitu: 1 step (14 ALU op; dominira 6 MUL × ⌈571/D⌉) + 3 takta režije
(swap/reswap/next). Ukupno ≈ 285k taktova (D=8) / 100k (D=32) po k·P.
