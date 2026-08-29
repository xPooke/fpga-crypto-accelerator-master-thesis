# SPEC: `ec_scalar_mult` — Montgomery lestvica (k·P, x-only)

**Zlatni model:** `scalar_mult_ct` u `ECDH_python/ec_ladder.py` (red po red).
**Vektori:** `sim/ladder_vec_gf4.txt` (k=1..14) i `ladder_vec_b571.txt` (20
slučajnih), format `k x y b X1 Z1 X2 Z2 xa ya` — modul se poredi sa kolonama
`X1 Z1 X2 Z2` (xa/ya su za kasniji `ec_mxy`).

## Namena

Izračuna stanje lestvice za k·P: iz skalara `k`, bazne x-koordinate `xb` i
parametra krive `b` vraća `(X1,Z1,X2,Z2)` — projektivno x-only stanje gde je
x(k·P) = X1/Z1 i x((k+1)·P) = X2/Z2. **Bez inverzije** — afinu konverziju i
y-recovery radi `ec_mxy` posle. Ovo je "dirigent": instancira i poseduje
`gf_alu`, `ec_cswap` i `ec_point_step`; sam ne računa ništa u polju.

## Interfejs

### Generici

| Ime   | Tip              | Default   | Opis                                  |
|-------|------------------|-----------|---------------------------------------|
| `G_M` | integer          | 4         | širina polja                          |
| `G_D` | integer          | 1         | digit-serial širina za `gf_mul`       |
| `G_F` | std_logic_vector | "10011"   | redukcioni polinom SA vodećim bitom   |

(G_D i G_F samo prolaze do interne `gf_alu`.)

### Portovi

| Port      | Smer | Širina | Opis                                        |
|-----------|------|--------|---------------------------------------------|
| `i_clk`   | in   | 1      | takt                                        |
| `i_resetn`  | in   | 1      | sinhroni reset, aktivna nula                |
| `i_start` | in   | 1      | puls: kreni (ulazi se snimaju tada)         |
| `i_k`     | in   | G_M    | skalar, **k ≥ 1** (k=0 nedefinisano)        |
| `i_xb`    | in   | G_M    | x bazne tačke P                             |
| `i_b`     | in   | G_M    | parametar krive                             |
| `o_x1`    | out  | G_M    | X1 (lestvica, x(k·P)=X1/Z1)                 |
| `o_z1`    | out  | G_M    | Z1                                          |
| `o_x2`    | out  | G_M    | X2 (x((k+1)·P)=X2/Z2 — treba za Mxy)        |
| `o_z2`    | out  | G_M    | Z2                                          |
| `o_busy`  | out  | 1      | '1' van S_IDLE                              |
| `o_done`  | out  | 1      | puls 1 takt, rezultat važi                  |

Nema ALU-klijent portova: ALU je unutra. (Kad dođe `ec_mxy`, dobija svoj
klijent priključak preko mux-a — vidi "Kasnije" dole.)

## Unutrašnja struktura

```
u_alu   : gf_alu(G_M, G_D, G_F)     -- jedini računski resurs
u_step  : ec_point_step(G_M)        -- klijent magistrala vezana DIREKTNO na u_alu
u_cswap : ec_cswap(G_M)             -- ulazi = ladder registri, swap = tekući bit
```

Registri: `r_x1, r_z1, r_x2, r_z2` (stanje lestvice), `r_k` (šift-registar
skalara), `r_xb, r_b` (snapshot), `r_cnt` (brojač preostalih bitova).

Tekući bit je uvek **MSB od `r_k`**: `w_bit = r_k(G_M-1)`; posle svakog bita
`r_k` se šiftuje ulevo. `ec_cswap` stalno gleda ladder registre
(`i_swap => w_bit`), FSM samo bira KAD se njegovi izlazi upisuju nazad.

## Algoritam (preslikan `scalar_mult_ct`)

### 1. S_IDLE → snapshot
Na `i_start`: `r_k ⇐ i_k`, `r_xb ⇐ i_xb`, `r_b ⇐ i_b`,
`(r_x1,r_z1) ⇐ (i_xb, 1)`, `(r_x2,r_z2) ⇐ (i_xb, 1)` (privremeno — vidi init
trik), `r_cnt ⇐ G_M`.

### 2. S_ALIGN — hardverski `bin(k)[3:]`
Dok je `r_k(G_M-1) = '0'`: `r_k <<= 1`, `r_cnt -= 1` (1 takt po šiftu).
Kad MSB postane '1': šiftuj još jednom (MSB je "potrošen" init stanjem
(P, 2P)), `r_cnt -= 1`. Sada je `r_cnt = bitlen(k) − 1` = broj iteracija,
a tekući bit petlje je uvek `r_k(G_M-1)`.
Napomena za tezu: broj iteracija zavisi od bitlen(k) (curi log₂k, standardno
prihvatljivo); tok SVAKOG bita je identičan — to je poenta cswap lestvice.

### 3. S_INIT_2P — P2 = 2·P **preko point_step-a** (trik, bez posebne logike)
Pusti `u_step` sa P1 = P2 = (xb,1): step vraća nP1 = mdouble(P1) = **2P** —
tačno ono što init traži. Uzmi `(r_x2,r_z2) ⇐ (step.o_x1, step.o_z1)`,
a nP2 (madd dve iste tačke → nZ2=0) **odbaci**; (r_x1,r_z1) ostaje (xb,1).
Ako je `r_cnt = 0` (k=1 ⇒ `bin(k)[3:]=''`) → pravo u S_DONE:
rezultat je (xb,1,2P) kao u Python-u.

### 4. Petlja po bitu (dok `r_cnt > 0`), identično Python šablonu:
| Stanje    | Radnja                                                        | Takta |
|-----------|---------------------------------------------------------------|-------|
| `S_SWAP` | ladder regs ⇐ cswap izlazi (swap = `w_bit`)                   | 1     |
| `S_POINT_STEP` | strob `u_step`, čekaj `done`, regs ⇐ step izlazi (nX1..nZ2)   | ~14 op|
| `S_RESWAP` | ladder regs ⇐ cswap izlazi (isti `w_bit`!)                    | 1     |
| `S_NEXT_BIT` | `r_k <<= 1`, `r_cnt -= 1`; `r_cnt=0` → S_DONE, inače S_SWAP  | 1     |

Strob ka step-u: ista bug-#5 disciplina (step je brz da digne busy — 1-takt
strob iz prelaznog stanja, ili gejtovan na `step_busy='0'`).

### 5. S_DONE
`o_done` puls; `o_x1..o_z2` = ladder registri. Nazad u S_IDLE.

## Procena vremena (za D-sweep tabelu)

Po bitu: 14 ALU op ≈ 6·(⌈m/D⌉+rezija) + 5·~4 + 3·~4 + 3 takta swap/next.
Ukupno ≈ bitlen(k) × to (init korak = još jedan step). B-571, D=8:
~ 570 × ~500 ≈ 285k taktova po k·P.

## Verifikacija

- `sim/tb_ec_scalar_mult_vec.vhd`: instancira SAMO ovaj modul (ALU je unutra),
  čita `ladder_vec_*.txt`, vozi `k, xb, b` (kolone y/xa/ya preskače), poredi
  4 izlaza sa `X1 Z1 X2 Z2`.
- GF(2⁴): svih 14 vektora (k=1..14; pokriva i k=1 rubni slučaj bez iteracija).
- B-571: 20 vektora, `G_D=8` (i po volji 32); duga simulacija (~6M taktova).

## Bezbednosna beleška — curenje bitlen(k) (za tezu; RAZMISLITI o protivmeri)

Po-bitni tok je konstantan (cswap: identične operacije za bit 0 i 1), ali
**ukupan broj taktova zavisi od bitlen(k)**: S_ALIGN šiftuje onoliko puta
koliko ima vodećih nula, a petlja se vrti bitlen(k)−1 puta. Napadač koji meri
vreme saznaje poziciju MSB-a skalara — NE i vrednosti bitova.

- **ECDH sa slučajnim k: prihvatljivo.** k je uniforman na [1, n−1], MSB je
  postavljen u ~50% slučajeva → u proseku procuri ~2 bita informacije;
  ključ od 570 bitova time nije ugrožen.
- **ECDSA nonce: OPASNO.** Ista lestvica se ne sme bez zaštite koristiti za
  potpisivanje: iz hiljada potpisa napadač izdvoji one sa kraćim noncem
  (brže izvršavanje) i lattice napadom (HNP) rekonstruiše privatni ključ.
  Stvarni napadi upravo ovog tipa: **Minerva (2019)**, **TPM-Fail (2019)**.
- **Protivmere (kandidat za Fazu 2 / diskusiju u tezi):**
  1. *Scalar padding:* računaj sa k' = k + n ili k + 2n (n = red grupe;
     n·P = O pa je rezultat isti), birano tako da je bitlen(k') fiksan →
     ALIGN i petlja uvek traju isto. Samo jedan sabirač pre lestvice,
     lestvica se ne menja.
  2. *Clamping (Curve25519 stil):* protokolom fiksirati gornji bit skalara.
  3. *Fiksni broj iteracija:* uvek m−1 koraka, upis rezultata maskiran
     (write-enable) dok prava jedinica ne naiđe.
- **Odluka za Fazu 1:** ostaje varijabilan broj iteracija — poklapa se 1:1
  sa zlatnim modelom (`bin(k)[3:]` u `scalar_mult_ct`) i vektorima; u tezi
  eksplicitno navesti ograničenje + protivmeru.

## Kasnije (ne sada)

- `ec_mxy` klijent: ALU magistrala dobija 2:1 mux (step / mxy) po stanju FSM-a
  — isti obrazac kao arbitar u `gf_alu.vhd` (S_INV → inv vozi množač).
- Paralelno jezgro: više množača u step-u, uz nepromenjen interfejs ovog
  modula. Spojeni dupli cswap između susednih bitova (swap = kᵢ xor kᵢ₊₁) i
  double-buffering ostaju moguće dorade.
