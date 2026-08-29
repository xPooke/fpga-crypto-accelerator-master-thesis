# gf_alu — GF(2^m) ALU: čist izvršilac 4 operacije

**RTL:** `src/gf_alu.vhd` (+ `src/gf_alu_pkg.vhd`) · **Slika:** `gf_alu.svg`
· **Verifikacija:** `tb_gf_alu_vec`: GF(2⁴) **ALL 543 PASS**; B-571 **ALL 72 PASS**
(G_D=8 i G_D=32)

## Posao (tri rečenice)

1. Primi operaciju (`i_op` ∈ {ALU_ADD, ALU_SQR, ALU_MUL, ALU_INV}) i operande,
   na `i_start` ode u busy, na kraju pulsira `o_done` sa rezultatom — **čist
   izvršilac bez registarskog fajla** (žive promenljive drže klijenti).
2. ADD/SQR su kombinacioni (rezultat za 1 takt kroz `S_COMB`); MUL/INV
   sekvencijalni (čekaju done podmodula).
3. **Jedna `gf_mul` se DELI** između direktnog MUL puta i `gf_inv`-a
   (inv je mul-klijent) — interni arbitar po stanju.

## gf_alu_pkg (dokumentovan ovde)

Paket nosi: `alu_op_t` (skup operacija) i `num_bits(n)` (širina brojača —
jedini izvor istine, koriste ga `gf_mul` brojač digita, `gf_inv` šetnja po
eksponentu, `r_pc` u step/mxy). Deljeni helperi se NE re-deklarišu lokalno.

## Ekonomija deljenja (zašto baš ovakva podela)

Deljenje bloka se isplati samo kad je blok >> mux koji ga deli (mux od m bita
≈ m LUT-ova): `gf_mul` (digit-serial, hiljade LUT) → **deli se**; `gf_add`/
`gf_sqr` (~m LUT, 1 nivo) → mux bi pojeo uštedu → **repliciraju se** (privatne
instance). Registri su na FPGA jeftini — minimizuje se logika množača.

## Interfejs

Generici: `G_M`, `G_D` (digit širina gf_mul), `G_F`. Portovi: standard +
`i_op/i_a/i_b → o_res/o_busy/o_done`. Kod INV se `i_b` ignoriše.

## Mašina stanja

| Stanje | Šta radi | Izlaz |
|---|---|---|
| `S_IDLE` | snapshot `a, b, op` na start | po `i_op` → `S_COMB` / `S_MUL` / `S_INV` |
| `S_COMB` | upis add/sqr rezultata (kombinacioni, 1 takt) | → `S_DONE` |
| `S_MUL` | strob ka gf_mul (gejtovan na busy), čeka done | → `S_DONE` |
| `S_INV` | strob ka gf_inv; **arbitar: gf_inv vozi množač** | → `S_DONE` |
| `S_DONE` | done puls | → `S_IDLE` |

**Interni arbitar množača** (obrazac ponovljen sprat više u `ecdh_top`):
mux samo na `start/a/b` ka `gf_mul` (`S_INV` → gf_inv-ove žice, inače direktni
put); `busy/done/res` se granaju — gf_inv ih uzorkuje samo u svojim MUL
stanjima, direktni put samo u `S_MUL`.

## Cena po operaciji (taktovi, kroz handshake)

ADD/SQR ≈ 4 (režija handshake-a dominira — „cena uniformnosti" Faze 1,
kandidat za lokalne mreže u Fazi 2); MUL ≈ ⌈m/G_D⌉ + 4;
INV ≈ (m−1) sqr + ~13 mul (B-571; vidi `gf_inv.md`).
