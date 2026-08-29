# gf_inv — GF(2^m) inverzija, Itoh–Tsujii (binarni metod)

**RTL:** `src/gf_inv.vhd` · **Slika:** `gf_inv_fsm.svg` · **Teorija:**
`Ucenje_ECDH.md`, Lekcija 4 · **Verifikacija:** `tb_gf_inv_vec` (instancira
inv + mul, spaja klijent magistralu): GF(2⁴) **ALL 15**, GF(2⁷) **ALL 127**,
B-571 uzorak **ALL 36 PASS**; regresija G_D ∈ {1,2,4,8}

## Posao (tri rečenice)

1. `a⁻¹ = (β_n)², n = m−1`, gde je `β_t = a^(2^t−1)` (eksponent = t jedinica):
   niz od n jedinica se gradi čitajući bitove broja n MSB-first — **UDVOJ**
   (`β_t^(2^t)·β_t`, t→2t) uvek, pa **„+1"** (`β_t²·a`, t→t+1) ako je bit 1;
   finale = jedno kvadriranje.
2. Cena je fiksna u kvadratima (**m−1 uvek** — invarijanta) a bira se samo
   broj množenja: binarni metod daje `⌊log₂n⌋ + hw(n) − 1` = **13 za B-571**
   (optimalan lanac 12, ali traži hardkodovan ROM — žrtvovano za genericnost).
3. Resursi: `gf_sqr` **privatno** instanciran (jeftin; 1 kvadrat/takt u sprezi
   sa `r_beta`, kritični put uvek 1 sqr); `gf_mul` se **NE** instancira —
   modul je **mul-klijent** (`o_mul_*`/`i_mul_*`), ALU ga muxira na deljeni množač.

## Interfejs

Generici: `G_M ≥ 2`, `G_F` (asserti). Portovi: standard handshake + mul-klijent
magistrala (start gejtovan na `i_mul_busy` + `r_mul_launched` flag — start
tačno 1 takt). `a = 0` nema inverz — obrada na višem sloju (vraća đubre).

## Mašina stanja (8 stanja; dijagram u slici)

| Stanje | Šta radi | Izlaz |
|---|---|---|
| `S_IDLE` | snapshot: `β⇐a, saved⇐a, t⇐1, sqcnt⇐1, bitidx⇐MSB−1` | → `S_DBL_SQ` (m=2: → `S_FIN`) |
| `S_DBL_SQ` | multi-kvadrat: 1 kvadrat/takt, `sqcnt` odbrojava | `sqcnt=1` → `S_DBL_MUL` |
| `S_DBL_MUL` | `β ⇐ β·saved` preko deljenog množača; `t ⇐ 2t` | done: bit=1 → `S_P1_SQ`, inače → `S_NEXT` |
| `S_P1_SQ` | jedan kvadrat pred „+1" | → `S_P1_MUL` |
| `S_P1_MUL` | `β ⇐ β²·a` (množi sa **a**, ne sa saved!); `t ⇐ t+1` | done → `S_NEXT` |
| `S_NEXT` | sledeći bit: `bitidx−1`, `saved ⇐ β`, `sqcnt ⇐ t` | `bitidx=0` → `S_FIN`, inače → `S_DBL_SQ` |
| `S_FIN` | finalno JEDNO kvadriranje → `a⁻¹` | → `S_DONE` |
| `S_DONE` | done puls (`o_res = r_beta`) | → `S_IDLE` |

Mapiranje na teoriju: jedna „kretnja" = 2 stanja (multi-kvadrat brojačem, pa
množenje handshake-om). Recept se čita iz broja **n = m−1**, ne iz podatka a.

## Cena (B-571)

570 kvadrata (fiksno) + 13 množenja ≈ `570 + 13·(⌈571/G_D⌉ + režija)`
taktova; za G_D=8 ≈ 1,5k. U celom k·P inverzija postoji samo 3× (u `ec_mxy`).
