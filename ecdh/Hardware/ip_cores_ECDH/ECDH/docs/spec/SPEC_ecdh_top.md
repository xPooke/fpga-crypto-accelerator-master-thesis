# SPEC: `ecdh_top` — jezgro k·P: (k, P=(xb,yb), b) → afino (x, y)

**Zlatni model:** `scalar_mult` + `Mxy` u `ECDH_python/ec_ladder.py` (ceo lanac).
**Vektori:** `sim/ladder_vec_gf4.txt` / `ladder_vec_b571.txt` — kolone
`k x y b` su ULAZI, poslednje dve (`xa ya`) OČEKIVANI izlazi; projektivne
kolone X1..Z2 se preskaču (interne za ovaj modul). Novi generator nije potreban.

## Namena

Kompletno skalarno množenje sa afinim izlazom — jedini računski modul koji
omotač (`ecdh_axis_ip`) vidi. Instancira **jedan `gf_alu`** i dva njegova
klijenta i ništa sam ne računa:

- `u_smul` (`ec_scalar_mult`, refaktorisan u ALU-klijenta): Montgomery
  lestvica → projektivno stanje (X1,Z1,X2,Z2);
- `u_mxy` (`ec_mxy`): y-recovery → afino (x,y); ulazi su mu direktno žice
  sa izlaza `u_smul` + snapshot (xb,yb).

KEYGEN/SHARED razlika NE živi ovde — izlaz je uvek afino k·P; rutiranje
rezultata radi omotač. Slika: `figures/ecdh_top.svg`.

## Interfejs

Generici: `G_M` (širina polja), `G_D` (digit-serial), `G_F` (f SA vodećim
bitom, G_M+1 bitova) — prosleđuju se u `gf_alu`.

| Port | Smer | Širina | Opis |
|---|---|---|---|
| `i_clk`, `i_resetn`, `i_start` | in | 1 | standard (sinhroni rstn, 1-takt start) |
| `i_k`  | in | G_M | skalar (privatni ključ), k ≥ 1 |
| `i_xb` | in | G_M | x bazne tačke P (xb ≠ 0) |
| `i_yb` | in | G_M | y bazne tačke P (samo za mxy) |
| `i_b`  | in | G_M | parametar krive |
| `o_x`, `o_y` | out | G_M | afino k·P |
| `o_busy`, `o_done` | out | 1 | busy nivo, done puls (o_done = stanje S_DONE, 1 takt) |

**Preduslovi** (viši sloj / softver, teza §4.6): `k ≥ 1`, `xb ≠ 0`,
`k ≠ red(P)−1` (inače Z2 = 0 → INV(0) → đubre na izlazu; modul NE visi).

## Struktura i FSM

FSM: `S_IDLE → S_LADDER → S_MXY → S_DONE → S_IDLE`.

- **Snapshot** ulaza (k, xb, yb, b) u S_IDLE na `i_start` — deca se hrane iz
  registara, ulazi ne moraju biti stabilni tokom operacije.
- **Start strobovi ka deci:** 1 takt, gejtovani na child `busy`
  (bug-#5 disciplina iz dnevnika).
- **2:1 arbitar ALU magistrale** (isti obrazac kao arbitar u `gf_alu.vhd`):
  mux SAMO na `start/op/a/b` (`S_MXY` → mxy, inače smul); `busy/done/res`
  se granaju na OBA klijenta — bezbedno jer svaki uzorkuje `done` isključivo
  u svom aktivnom stanju.

## Cena (B-571, izmereno)

Dominira lestvica: D=8 ≈ 285k, D=32 ≈ 100k taktova po k·P; mxy dodaje
≈ 5,0k (D=8) / 2,7k (D=32) jednokratno (~3%). Top FSM režija: ~3 takta.

## Verifikacija

- `sim/tb_ecdh_top_vec.vhd` — instancira SAMO `ecdh_top` (ALU i klijenti su
  unutra); end-to-end `k,x,y,b → xa,ya` iz `ladder_vec_*.txt`.
- GF(2⁴): **ALL 14 PASS** (k=1..14; k=15 isključen — Z2=0 rub).
- B-571 (G_D=32): **ALL 20 PASS** (12.8.2026, GHDL 1.0.0; ≈ 100k taktova/k·P).
- Regresija dece posle refaktora: point_step 503, mxy 14, gf_alu 543 — PASS.

## Paralelno jezgro

Paralelno jezgro menja SAMO unutrašnjost (`ec_scalar_mult`/`ec_point_step` →
paralelna datapath mašina sa lokalnim ADD/SQR); interfejs ovog modula ostaje,
a završnu konverziju preuzima `ec_mxy_batch`.
