# ec_mxy — finalizacija k·P: y-recovery + afina konverzija

**RTL:** `src/ec_mxy.vhd` · **Slika:** šablon `../ec_point_step/mikroprogram_klijent.svg`
(blizanac step-a) · **Spec:** `../spec/SPEC_ec_mxy.md` · **Zlatni model:** `Mxy` u `ec_ladder.py`
· **Verifikacija:** `tb_ec_mxy_vec`: GF(2⁴) **ALL 14 PASS**; B-571 **ALL 20 PASS**
(D=8 i D=32; izmereno ≈5,0k / 2,7k taktova po pozivu)

## Posao (tri rečenice)

1. Iz projektivnog stanja lestvice `(X1,Z1,X2,Z2)` + baze `(xb,yb)` pravi
   pravu afinu tačku: `x = X1/Z1`, `y` po Mxy formuli (y-recovery).
2. **Jedino mesto u celom algoritmu gde se koristi ALU_INV** — 3 inverzije
   (redovi 1, 3, 12); lestvica nema nijednu.
3. Strukturno **blizanac `ec_point_step`-a**: isti mikroprogram-klijent šablon
   (FSM `S_IDLE/S_ISSUE/S_WAIT/S_DONE` + `r_pc` 1..14), druga tabela:
   **3 INV + 5 MUL + 1 SQR + 5 ADD** (slučajnost: opet 14 redova).

## Formula

```
x1 = X1/Z1                                       (afina x od k·P)
y1 = (x1+x)·[ (x1+x)(x2+x) + x² + y ]·x⁻¹ + y    (x2 = X2/Z2)
```

## Interfejs

Generik: `G_M`. Ulazi `i_x1/z1/x2/z2` (direktno žice sa lestvice), `i_xb`,
`i_yb` (y baze — samo ovom modulu treba); izlazi `o_x`, `o_y`, `o_busy/o_done`;
+ ALU-klijent magistrala. **Preduslovi** (viši sloj): `xb ≠ 0`, `Z1 ≠ 0`,
`Z2 ≠ 0` (rub `k = red−1` daje Z2=0 → INV(0) → đubre, ne visi).

## Detalji vredni pažnje

- `r_rx` (afina x, rezultat reda 2) se koristi i kao **operand** reda 5 —
  isti obrazac kao `r_nz2` u step-u.
- Scratch `r_t1` nosi redom: `Z1⁻¹ → Z2⁻¹ → step1 → x⁻¹` — svaki potrošen pre
  pregaza (hazardi provereni u SPEC-u).
- Uvek se izvršava ceo (i za SHARED gde y formalno ne treba) — konstantan tok.

## Zašto odvojen od step-a (odluka ZA TEZU)

Spajanje u jedan mikrokodiran modul (28 redova, deljene banke registara,
~6,3k FF uštede na B-571) razmatrano i odbijeno: paralelno jezgro menja model
izvršavanja step-a (paralelna datapath mašina), a mxy zauvek ostaje
sekvencijalni klijent — spojen modul bi nosio oba motora. Puna analiza:
`../spec/SPEC_ec_mxy.md`, „Analiza alternative".

## Paralelno jezgro

U paralelnom jezgru ovu ulogu preuzima `ec_mxy_batch`: 3 inverzije → 1
(Montgomeryjeva simultana inverzija), ušteda ~7k taktova jednokratno;
interfejs prema jezgru ostaje isti.
