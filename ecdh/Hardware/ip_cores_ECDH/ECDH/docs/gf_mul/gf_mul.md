# gf_mul — GF(2^m) množač, bit/digit-serial

**RTL:** `src/gf_mul.vhd` · **Slika:** `gf_mul.svg` · **Teorija:** `Ucenje_ECDH.md`,
Lekcije 2/2b · **Verifikacija:** `tb_gf_mul_vec` GF(2⁴) iscrpno **ALL 256 PASS**
(+ B-571 306); `tb_gf_mul_btb` back-to-back **BTB ALL 256/306 PASS**;
regresija G_D ∈ {1,2,3,4,5,8} (GF(2⁴)) i {1,2,4,8,16,32} (B-571)

## Posao (tri rečenice)

1. `a·b mod f` MSB-first shift-and-add (Hornerova šema) sa **utkanom
   redukcijom**: akumulator nikad ne pređe m bita — svaki pod-korak šiftuje za
   1 i po potrebi XOR-uje donji deo f (redukcija = par XOR-ova, zato NIST bira
   retke pentanome).
2. **Digit-serial**: `G_D` ulančanih pod-koraka po taktu → `⌈m/G_D⌉` taktova
   po množenju; `G_D=1` = bit-serial (specijalan slučaj), `G_D=m` = potpuno
   kombinacioni. Kritični put ~ G_D ulančanih (šift+XOR) nivoa → f_max ~ 1/G_D.
3. **Konstantno vreme** (uvek isti broj taktova, nezavisno od operanada) —
   poželjno protiv timing napada. Nema DSP blokova (carry-less XOR aritmetika).

## Rekurzija (mapira se 1:1 na RTL)

```
q = ceil(m/D); acc = 0
for k = q-1 downto 0:          # 1 TAKT po digitu (p_MULTIPLY)
    for j = D-1 downto 0:      # D kombinacionih pod-koraka (bit_serial_mult)
        idx = k*D + j
        acc = acc·x mod f      # šift + uslovni XOR donjeg dela f
        if idx < m and a(idx): acc ^= b
```
Padding (kad D ne deli m): guard `idx < m` na najvišem digitu; `acc·x` za
padding pozicije je bezopasan (acc još 0).

## Interfejs

Generici: `G_M`, `G_D` ∈ 1..G_M (assert), `G_F` (f SA vodećim bitom, G_M+1
bita, assert). Portovi: standard handshake; `a`/`b` se uzorkuju na start.

## Mašina stanja

| Stanje | Šta radi | Izlaz |
|---|---|---|
| `S_IDLE` | čeka start (snapshot a,b; acc=0; cnt=q−1) | → `S_CALCULATE` |
| `S_CALCULATE` | 1 digit po taktu, `r_cnt` odbrojava | `r_cnt=0` → `S_DONE` |
| `S_DONE` | `o_done` + `o_res` (kombinacioni iz acc) | start=1 → `S_CALCULATE` (**back-to-back**), inače → `S_IDLE` |

**Back-to-back**: držanjem `i_start=1` u `S_DONE` taj takt se reciklira kao
load sledećih operanada → jedan rezultat svakih `⌈m/G_D⌉+1` taktova, bez
`S_IDLE` mehura. Producent mora postaviti naredne operande RANO (potvrđeno
`tb_gf_mul_btb` scoreboard-om).

## Cena

`load(1, besplatan u BTB) + compute(⌈m/G_D⌉) + output(1)`. Ovo je **knoba #1**
Faze 1: G_D ↑ → manje taktova, više LUT-ova (D-sweep tabela za tezu predstoji).
