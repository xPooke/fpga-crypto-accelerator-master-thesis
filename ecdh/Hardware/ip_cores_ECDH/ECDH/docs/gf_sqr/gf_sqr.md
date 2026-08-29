# gf_sqr — GF(2^m) kvadriranje (kombinaciono)

**RTL:** `src/gf_sqr.vhd` · **Teorija:** `Ucenje_ECDH.md`, Lekcija 3; analiza
dubine `ECDH_python/gf_sqr_depth.py` · **Verifikacija:** `tb_gf_sqr_vec`
(bez takta, protiv `gf_mul(a,a)` zlatnog modela): GF(2⁴) **ALL 16**,
B-571 **ALL 307 PASS**

## Posao

Kvadriranje je u char-2 polju **linearno** (Frobenius): `a² = Σ aᵢ·x^(2i)` —
unakrsni članovi nestaju mod 2. Hardver je zato čista XOR mreža u dva fiksna
koraka: (1) **razmicanje** — bit i → pozicija 2i (čisto ožičenje, neparne
pozicije nula); (2) **redukcija** razmaknutog polinoma (stepen do 2m−2)
po f, odozgo nadole — fiksni XOR-ovi.

Bez registra i takta — registrovanje radi potrošač. Konstantno vreme.

## Zašto poseban blok (a ne `mul(a,a)`)

Kvadrat kroz množač = ⌈m/G_D⌉ taktova; ovako = **1 LUT6 nivo za B-571**
(max XOR fan-in po izlaznom bitu = 4, izračunato alatom; ista dubina kao
`gf_add`, ~571 LUT, 0 FF). Presudno za `gf_inv` (Itoh–Tsujii = 570 kvadrata:
570 taktova umesto ~40k kroz množač).

## Interfejs

Generici: `G_M`, `G_F` (f SA vodećim bitom, G_M+1 bita — assert).
`i_a → o_sq`, ništa više.

## Napomena za ulančavanje

Jedan sqr = 1 LUT nivo, ali k ulančanih kvadrata kombinaciono = k nivoa —
zato `gf_inv` registruje između (1 kvadrat/takt kroz `r_beta` spregu).
