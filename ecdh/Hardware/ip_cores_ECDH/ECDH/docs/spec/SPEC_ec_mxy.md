# SPEC: `ec_mxy` — finalizacija: (X1,Z1,X2,Z2) → afino k·P = (x1, y1)

**Zlatni model:** `Mxy` u `ECDH_python/ec_ladder.py` (ćelija 8 notebook-a) —
mikroprogram dole je NJEN prepis red-po-red, bez algebarskih prerada.
**Vektori:** postojeći `sim/ladder_vec_gf4.txt` / `ladder_vec_b571.txt` —
kolone `X1 Z1 X2 Z2` su ULAZI ovog modula, `x y` su (xb, yb), a poslednje
dve kolone `xa ya` su OČEKIVANI izlazi. Novi generator nije potreban.

## Namena

Poslednji računski korak k·P: iz projektivnog stanja lestvice napravi pravu
afinu tačku:
```
x1 = X1/Z1                                       (afina x od k·P)
y1 = (x1+x)·[ (x1+x)(x2+x) + x² + y ]·x⁻¹ + y    (y-recovery; x2 = X2/Z2)
```
Ovde žive SVE inverzije algoritma (ALU_INV, Itoh–Tsujii kroz gf_alu) —
lestvica ih nema nijednu. ALU-klijent kao `ec_point_step`: ne instancira
aritmetiku, izdaje operacije deljenoj `gf_alu`.

**Preduslovi** (nasleđeni iz Python docstring-a): `x ≠ 0`, `Z1 ≠ 0`, `Z2 ≠ 0`.
Inače gf_inv(0) vraća đubre (poznat rub: k = red−1 daje Z2 = 0 — P2 = O).
Proveru radi viši sloj / softver, NE ovaj modul.

## Interfejs

Generik: `G_M` (širina polja). Portovi — isti klijent šablon kao point_step:

| Port | Smer | Širina | Opis |
|---|---|---|---|
| `i_clk`, `i_resetn`, `i_start` | in | 1 | standard (sinhroni rstn, 1-takt start) |
| `i_x1, i_z1, i_x2, i_z2` | in | G_M | stanje lestvice (izlaz ec_scalar_mult) |
| `i_xb` | in | G_M | x bazne tačke P |
| `i_yb` | in | G_M | **y bazne tačke P** (novo — treba formuli za y1) |
| `o_x`  | out | G_M | afino x od k·P |
| `o_y`  | out | G_M | afino y od k·P |
| `o_busy`, `o_done` | out | 1 | busy nivo, done puls |
| `o_alu_start/op/a/b`, `i_alu_busy/done/res` | — | — | ALU-klijent magistrala |

## Mikroprogram (prepis Markove `Mxy`, 14 operacija)

Registri: snapshot `r_x1,r_z1,r_x2,r_z2,r_xb,r_yb`; scratch `r_t1,r_t2,r_t3`;
rezultat `r_rx` (=x1 afino; pazi — koristi se i kao operand!), `r_ry`.

| # | Op  | a     | b     | dst   | Python linija |
|---|-----|-------|-------|-------|----------------------------------|
| 1 | INV | r_z1  | —     | r_t1  | `Z1_inv = gf_inv(Z1)` |
| 2 | MUL | r_x1  | r_t1  | r_rx  | `x1 = X1·Z1_inv` (gotova afina x!) |
| 3 | INV | r_z2  | —     | r_t1  | `Z2_inv = gf_inv(Z2)` |
| 4 | MUL | r_x2  | r_t1  | r_t2  | `x2 = X2·Z2_inv` |
| 5 | ADD | r_rx  | r_xb  | r_t1  | `step1 = x1 + x` |
| 6 | ADD | r_t2  | r_xb  | r_t2  | `x2 + x` |
| 7 | MUL | r_t1  | r_t2  | r_t2  | `step2 = step1·(x2+x)` |
| 8 | SQR | r_xb  | —     | r_t3  | `x²` |
| 9 | ADD | r_t2  | r_t3  | r_t2  | `step2 + x²` |
| 10| ADD | r_t2  | r_yb  | r_t2  | `step3 = … + y` |
| 11| MUL | r_t1  | r_t2  | r_t2  | `step1·step3` |
| 12| INV | r_xb  | —     | r_t1  | `x_inv = gf_inv(x)` |
| 13| MUL | r_t2  | r_t1  | r_t2  | `step4 = …·x_inv` |
| 14| ADD | r_t2  | r_yb  | r_ry  | `y1 = step4 + y` |

Zbir: **3 INV + 5 MUL + 1 SQR + 5 ADD = 14 operacija** (slučajnost: isto 14
kao point_step). Hazardi provereni: T1 nosi redom Z1⁻¹ → Z2⁻¹ → step1 → x⁻¹,
svaki se potroši pre pregaza (op2 pre op3, op4 pre op5, op11 pre op12).

## FSM

Identičan `ec_point_step`-u: S_IDLE / S_ISSUE / S_WAIT / S_DONE + `r_pc`
1..14, strob gejtovan na busy, upis na done, pc napreduje na done. Jedina
razlika: tabela gore + ALU_INV se KORISTI (u point_step-u nije).

## Cena (procena, B-571)

Dominira 3× INV: svaka je ~570 SQR + 13 MUL kroz gf_alu ≈ 570·4 + 13·(m/D
+ rezija). Za D=8: INV ≈ 3300 taktova → ceo mxy ≈ **~10.500 taktova** —
jednokratno, ~3–4% vremena celog k·P. Zato u Fazi 1 NE optimizujemo.

## Verifikacija

- `sim/tb_ec_mxy_vec.vhd`: instancira ec_mxy + gf_alu (klijent magistrala,
  kao tb_ec_point_step_vec), čita `ladder_vec_*.txt`: ulazi = kolone
  X1 Z1 X2 Z2 + x y, očekivanje = xa ya (kolona k se preskače).
- GF(2⁴): 14 vektora (k=15 već isključen iz fajla — Z2=0 rub).
- B-571: 20 vektora (datapath; slučajni Z1,Z2,x praktično nikad 0).

## Analiza alternative: spojen step+mxy modul (ZA TEZU — Markova ideja, 10.8.2026)

Razmatrano: jedan modul sa `i_mode` ulazom (0 = point_step, 1 = mxy) umesto
dva odvojena — mikrokodirana mašina sa 28 redova tabele.

**Dobit (stvarna):** deljene banke registara. Na B-571 svaki registar je
571 FF; odvojen mxy nosi ~11 svojih registara ≈ **6.300 FF duplikata** koji
"spavaju" dok drugi modul radi. Uz to deljen FSM/handshake (sitno) i ALU
magistrala bez klijent-mux-a. Cena spajanja u Fazi 1 mala: isti upisni put
(`i_alu_res` → dst po pc), samo duži case.

**Zašto je ODBIJENO za osnovno jezgro — paralelno jezgro menja MODEL IZVRŠAVANJA step-a:**
step u paralelnom jezgru gubi pc/issue/wait strukturu (b·Z⁴ → fiksna XOR mreža, ADD/SQR
→ lokalno kombinaciono, MUL → 2–3 sopstvena množača sa statičkim rasporedom,
~3 runde/bit sa 2 množača, ~2 sa 3) — postaje datapath mašina, NE
mikroprogram-klijent. Mxy (izvršava se 1× po k·P, 3–4% vremena) zauvek
ostaje sekvencijalni ALU-klijent. Spojen modul bi u Fazi 2 morao da drži
OBA motora u istom telu (stara issue/wait mašinerija samo za mode=1 + nova
paralelna datapath za mode=0, mux-evi na deljenim registrima), čime nestaje
i razlog spajanja. Odvojeni moduli → prelazak na paralelno jezgro = zamena
step implementacije, mxy netaknut (isti potpis).

**Kontekst resursa:** 6,3k FF = ~2,7% FF-ova na K26 (234k), a dizajn je
LUT-dominantan (571-bitni XOR-ovi, množač) — ušteda realna ali ne pomera
usko grlo. Zaključak za tezu: trade-off površina-vs-modularnost rešen u
korist modularnosti zbog planirane druge realizacije; deljenje banki
registara ostaje dokumentovana opcija ako bi se gradila samo jedna
realizacija.

## Kasnije (ne sada)

- U paralelnom jezgru realizovano kroz `ec_mxy_batch`: 3 inverzije → 1
  (Montgomeryjeva simultana inverzija) — ušteda ~7000 taktova jednokratno;
  interfejs prema jezgru ostaje isti.
- U ec_scalar_mult (ili top): 2:1 mux ALU magistrale step/mxy po stanju —
  isti obrazac kao arbitar množača u gf_alu.vhd.
