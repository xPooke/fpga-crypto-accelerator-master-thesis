# ecdh_top — ECDH jezgro: (k, P, b) → afino k·P

**RTL:** `src/ecdh_top.vhd` · **Slika:** `ecdh_top.svg` · **Spec:** `../spec/SPEC_ecdh_top.md`
· **Verifikacija:** `tb_ecdh_top_vec` (end-to-end `k,x,y,b → xa,ya` iz
`ladder_vec_*.txt`): GF(2⁴) **ALL 14 PASS**; B-571 **ALL 20 PASS** (D=32,
≈100k taktova/k·P)

## Posao (tri rečenice)

1. Kompletno skalarno množenje sa afinim izlazom: `(k, xb, yb, b) → (x, y) = k·P`
   — modul u kom se sastaju svi delovi Faze 1 i **jedini vlasnik `gf_alu`-a**.
2. Sam ne računa ništa: klijent A (`u_smul`, Montgomery lestvica → projektivno
   X1..Z2, ~99% vremena) i klijent B (`u_mxy`, y-recovery → afino, jedine 3
   inverzije) rade sav posao nad deljenim ALU-om.
3. KEYGEN/SHARED razlika ne postoji ovde — izlaz je uvek puna afina tačka;
   rutiranje radi omotač.

## Interfejs

Generici: `G_M`, `G_D`, `G_F` (prosleđuju se ALU-u).

| Port | Smer | Opis |
|---|---|---|
| `i_clk`, `i_resetn`, `i_start` | in | standard (snapshot ulaza na start) |
| `i_k`, `i_xb`, `i_yb`, `i_b` | in | skalar, bazna tačka, parametar krive |
| `o_x`, `o_y` | out | afino k·P (važi uz `o_done`) |
| `o_busy`, `o_done` | out | busy nivo, done puls |

**Preduslovi** (viši sloj): `k ≥ 1`, `xb ≠ 0`, `k ≠ red(P)−1` — za prekršaj
izlazi đubre, ali ništa ne visi (lestvica ima defanzivni izlaz za k=0,
INV(0) vraća đubre a ne petlju).

## Mašina stanja

| Stanje | Šta radi | Izlaz |
|---|---|---|
| `S_IDLE` | snapshot `k, xb, yb, b` na `i_start` | → `S_LADDER` |
| `S_LADDER` | lestvica radi (start strob gejtovan na busy) | `smul.done` → `S_MXY` |
| `S_MXY` | y-recovery radi | `mxy.done` → `S_DONE` |
| `S_DONE` | `o_done` puls, rezultat na izlazima | → `S_IDLE` |

## Dva detalja koja nose modul

**① 2:1 arbitar ALU magistrale — namerno asimetričan.** Mux postoji samo na
smeru *ka* ALU-u (`start/op/a/b`; `S_MXY` → mxy, inače smul). Povratni smer
(`busy/done/res`) se **grana na oba klijenta** — bezbedno jer svaki uzorkuje
`done` isključivo u svom aktivnom stanju. Preklop muxa na prelazu
`S_LADDER→S_MXY` ne može ništa da preseče: u taktu lestvičinog `done` njena
poslednja ALU operacija je završena više taktova ranije (posle nje prolaze
`S_RESWAP → S_NEXT_BIT → S_DONE`), pa je ALU u `S_IDLE`. Drugi sloj zaštite:
mxy-jev start je ionako 0 van njegovog `S_ISSUE`, u koji ne može ući bez
`i_start` od topa. Isti obrazac kao arbitar množača unutar `gf_alu`.

**② Veza lestvica → mxy je gola žica, bez registara u topu.**
`w_smul_x1..z2 → i_x1..z2` mxy-ja direktno: lestvica posle `done` drži izlazne
registre nepromenjenim (neće se restartovati dok top ne prođe ceo krug), a mxy
snapshotuje svoje ulaze na svoj start. Nula FF-ova, nula hazarda.

## Cena (B-571, izmereno)

`S_LADDER` ≈ 285k taktova (D=8) / 100k (D=32); `S_MXY` ≈ 5,0k / 2,7k
(~1–3%, jednokratno); top režija ~3 takta.

## Paralelno jezgro

Paralelno jezgro (`ecdh_core_low_latency`) menja SAMO unutrašnjost — korak
lestvice postaje paralelna datapath mašina (`ec_point_step_par`), a završnu
konverziju preuzima `ec_mxy_batch`; spoljašnji interfejs ostaje isti.
