# ec_point_step — jedan korak lestvice (mikroprogram-klijent)

**RTL:** `src/ec_point_step.vhd` · **Slika:** `mikroprogram_klijent.svg`
(zajednički šablon sa `ec_mxy`) · **Spec:** `../spec/SPEC_ec_point_step.md`
· **Formule:** x-only korak Montgomeryjevih merdevina (poglavlje 3 rada); zlatni model `madd`/`mdouble` u `ec_ladder.py`
· **Verifikacija:** `tb_ec_point_step_vec` (instancira step + gf_alu):
GF(2⁴) **ALL 503 PASS**; B-571 **ALL 20 PASS** (D=8, D=32)

## Posao (tri rečenice)

1. Jedan FIKSNI korak Montgomery lestvice za ulaze posle cswap-a:
   `nP2 = madd(P2, P1, xb)` i `nP1 = mdouble(P1, b)` — uvek obe operacije,
   bez obzira na bit (bit rešava cswap izvan ovog modula).
2. **ALU-klijent**: ne instancira aritmetiku; izdaje **14 operacija**
   (6 MUL + 5 SQR + 3 ADD, bez INV) deljenoj `gf_alu` preko handshake magistrale.
3. Mikroprogram: `r_pc` 1..14 bira red tabele (`p_ALU_OPS` = kolone op/a/b,
   case u `p_DATAPATH` = kolona dst); redosled je 1:1 prepis SPEC tabele.

## Interfejs

Generik: `G_M`. Ulazi `i_x1/z1/x2/z2` (posle cswap-a!), `i_xb`, `i_b`;
izlazi `o_x1/z1` (nP1), `o_x2/z2` (nP2), `o_busy/o_done`;
+ ALU-klijent magistrala (7 portova).

## Mašina stanja (mikroprogram-klijent šablon)

| Stanje | Šta radi | Izlaz |
|---|---|---|
| `S_IDLE` | ulazni registri prate ulaze; start → `r_pc ⇐ 1` | → `S_WAIT` |
| `S_ISSUE` | `o_alu_start='1'` dok je ALU idle (1-takt strob) | `alu_busy=1` → `S_WAIT` |
| `S_WAIT` | čeka `alu_done`; na done: upis rezultata po dst koloni, `r_pc+1` | done ∧ `r_pc=c_NUM_OPS` → `S_DONE`; `alu_busy=0` → `S_ISSUE` |
| `S_DONE` | done puls | → `S_IDLE` |

Discipline šablona (dele ga gf_inv→gf_mul, ec_mxy, ovaj modul):
strob gejtovan na `busy`; **pc napreduje na `done`** — tačno jednom po
operaciji (`S_ISSUE` traje 2 takta, napredovanje tamo bi preskakalo redove).

## Mikroprogram (sažetak; puna tabela u SPEC-u)

```
madd:    T1=X2·Z1  T2=X1·Z2  T3=T1+T2  nZ2=T3²  T3=T1·T2  T1=xb·nZ2  nX2=T1+T3
mdouble: T1=X1²  T2=Z1²  nZ1=T1·T2  T1=X1⁴  T2=Z1⁴  T2=b·Z1⁴  nX1=T1+T2
```
Hazard napomena: `r_nz2` (rezultat reda 4) se koristi kao operand reda 6 —
dozvoljeno jer je upisan na done reda 4, dva reda ranije.

## Paralelno jezgro

U paralelnom jezgru ovaj modul je zamenjen iz korena (`ec_point_step_par`:
paralelna datapath mašina sa tri množača i lokalnim ADD/SQR) — zato je odvojen
od `ec_mxy` iako su blizanci (analiza: `../spec/SPEC_ec_mxy.md`).
