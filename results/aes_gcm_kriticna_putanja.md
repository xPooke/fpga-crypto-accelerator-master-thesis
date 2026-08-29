# Zašto AES-GCM staje oko 222 MHz

Merenja iz `aes_gcm_ipsec.csv`, `ghash_synth.csv` i `aes_synth.csv`, uz izvode
kritičnih putanja iz `aes_gcm/Results/synth_gcm_ipsec/*/timing.rpt` i rangiranje po
blokovima iz `aes_gcm/Results/tajming_ghash_forenzika/*/blocks.csv`.

Pitanje je bilo zašto GHASH sa množenjem u dva takta podigne sopstvenu učestanost za
trećinu, a u sastavljenom sistemu to ne donese skoro ništa.

## Lestvica ograničenja

Isti dizajn, mereno na četiri nivoa:

| šta je mereno | MULT_CYCLES = 1 | MULT_CYCLES = 2 |
|---|---|---|
| `GHASH_wrapper` sam | 262,86 | 348,51 |
| `gcm_enc_glue` sam | **227,46** | 302,18 |
| AES, 15 valjanih jezgara, sam | 265,75 | **265,75** |
| kompozit `gcm_enc` | 222,10 | 243,70 |

Podebljano je ono što u toj koloni vezuje.

Sa jednim taktom granicu drži lepak na 227,46 i kompozit padne 2,4 procenta ispod
njega. Sa dva takta lepak se penje na 302,18 i prestaje da bude granica, ali tada
granicu preuzima AES blok na 265,75, koji se nije pomerio. Onih 302 MHz nije bilo
dostižno ni u jednom trenutku.

Plafon je time porastao za `265,75 / 227,46 = 16,8` odsto, a dobijeno je 9,7. Razlika
je cena spajanja, koja raste sa 2,4 na 8,3 odsto jer je kompozit tešnji na periodi
4,225 ns nego na 4,545 ns.

## Dobitak od dva takta po konfiguraciji

| konfiguracija | MC=1 | MC=2 | dobitak |
|---|---|---|---|
| `GHASH_wrapper` sam | 262,86 | 348,51 | +32,6 % |
| `gcm_enc_glue` sam | 227,46 | 302,18 | +32,8 % |
| kripto enc, 1 jezgro | 222,25 | 309,84 | +39,4 % |
| kripto dec, 1 jezgro | 230,07 | 303,54 | +31,9 % |
| ipsec enc, 1 jezgro | 239,44 | 287,07 | +19,9 % |
| ipsec dec, 1 jezgro | 210,59 | 254,55 | +20,9 % |
| kripto enc, 15 jezgara | 222,10 | 243,70 | +9,7 % |
| kripto dec, 15 jezgara | 223,19 | 233,51 | +4,6 % |
| ipsec enc, 15 jezgara | 225,81 | 223,89 | −0,9 % |
| ipsec dec, 15 jezgara | 217,23 | 222,30 | +2,3 % |

Gubitak nije vezan za količinu logike oko GHASH-a, jer lepak sam dobija punih 32,8
odsto. Vezan je isključivo za broj AES jezgara.

Cena je pola propusnosti: `kripto_enc` pada sa 28,43 na 15,60 Gb/s. Zaključak je da
množenje u dva takta ne ide u rad kao radna tačka.

## Rangiranje po blokovima

`tajming_ghash_forenzika.tcl` ponovo implementira konfiguraciju na periodi na koju je
pretraga konvergirala i uzima najgoru putanju svakog bloka posebno, umesto jedne
najgore u celom dizajnu. Tekući RTL, dakle sa registrom na sporednom putu duzina.

**`kripto_enc`, 15 jezgara, MC = 1, perioda 4,545 ns**

| blok | slack | zaostatak | kašnjenje | nivoa |
|---|---|---|---|---|
| GHASH akumulator | 0,050 | 0,000 | 4,491 | 8 |
| AES proširenje ključa | 0,102 | 0,052 | 4,439 | 3 |
| AES jezgro, runda | 0,105 | 0,055 | 4,434 | 4 |
| GHASH upravljanje | 0,225 | 0,175 | 4,318 | 4 |
| AES raspodela po jezgrima | 0,304 | 0,254 | 4,112 | 9 |

Tri bloka u rasponu od 0,055 ns. Nema jednog krivca, sve troje je na granici
istovremeno, pa uklanjanje GHASH-a iz igre vredi tačno 0,05 ns.

**`kripto_enc_m2`, 15 jezgara, MC = 2, perioda 4,225 ns**

| blok | slack | zaostatak | kašnjenje | nivoa |
|---|---|---|---|---|
| AES proširenje ključa | 0,192 | 0,000 | 3,907 | 1 |
| AES jezgro, runda | 0,212 | 0,020 | 4,007 | 3 |
| GHASH upravljanje | 0,237 | 0,045 | 3,982 | 3 |
| AES raspodela po jezgrima | 0,317 | 0,125 | 3,905 | 2 |
| GHASH množač, dva takta | 0,368 | 0,176 | 3,853 | 6 |

Množač je pao na začelje, a napred je ostalo proširenje ključa.

**`kripto_enc_c1`, 1 jezgro, MC = 1, perioda 4,422 ns**

| blok | slack | zaostatak | kašnjenje | nivoa |
|---|---|---|---|---|
| GHASH akumulator | 0,110 | 0,000 | 4,307 | 8 |
| AES proširenje ključa | 0,168 | 0,058 | 4,251 | 5 |
| AES jezgro, runda | 0,247 | 0,137 | 4,169 | 5 |
| račun oznake | 0,286 | 0,176 | 4,007 | 0 |
| AES raspodela po jezgrima | 0,627 | 0,517 | 3,666 | 3 |

Ista slika, samo je razmak veći, pa dva takta ovde stvarno vrede 39 odsto.

Četvrta konfiguracija, `kripto_enc_c1_m2`, nije domerena. Njena kritična putanja je
poznata iz `synth_gcm_ipsec/kripto_enc_c1_m2/timing.rpt` i vodi kroz cevovodni
množač, `FSM_onehot_state_reg[2]` do `gen_pipelined.u_ghash/r_p32_reg[5][8]`, pet
nivoa logike.

## Šta guši proširenje ključa

Kritična putanja `kripto_enc` raspisana po vezama:

```
SLICE_X13Y127  r_window_reg[7]_rep_rep[5]/Q
   net (fo=32)    0,373 ns
SLICE_X12Y125  LUT6                  0,186 ns
   net (fo=1)     0,162 ns
SLICE_X12Y124  LUT6                  0,186 ns
   net (fo=6)     0,428 ns
SLICE_X18Y124  LUT5                  0,190 ns
   net (fo=18)    2,860 ns
SLICE_X50Y33   r_rk_reg[41][10]/D
```

Jedna veza nosi 2,860 od 4,496 ns, dakle 64 odsto cele putanje. Grananje joj je 18,
pa nije opterećenje nego rastojanje: sa `X18Y124` na `X50Y33`, trideset dve kolone i
devedeset jedan red preko čipa.

Uzrok je u `AES_multicore_wrapper.vhd:241` naspram `:258`. Postoji jedno
`KeyExpansion` koje opslužuje svih petnaest jezgara, pa raspoređivač razvuče niz
`r_rk` preko cele površine da bi ga sva jezgra dohvatila, a onda i sopstvena putanja
upisa u taj niz plaća to razvlačenje. Logike je tri nivoa i 0,674 ns, ostalo je žica,
85 odsto.

Lek je registarski nivo na izlazu proširenja ključa ili puštanje alata da replicira
logiku. Nijedno nije rađeno, jer je autor odlučio da `AES_multicore_wrapper` ostaje
kakav jeste. Ide u šesticu kao merena, a ne pretpostavljena stavka.

## Šta se ne sme pogrešno zapamtiti

Poklapanje `kripto_enc_c1` na 222,25 i `kripto_enc` na 222,10 MHz **je slučajno**.
Na jednom jezgru granicu drži GHASH akumulator, na petnaest je drži rutiranje niza
`r_rk`. Dva različita uzroka koja su slučajno ispala ista. Merena činjenica da
petnaest jezgara daje 14,96 puta veću propusnost stoji, ali objašnjenje nije da
GHASH prikiva oba kraja.

## Registar na sporednom putu duzina

Na jednom jezgru pomera kritičnu putanju sa `u_demux/r_len_valid` na
`u_glue/r_len_valid_q`, čime skraćuje ulaz u množač. Prosečan dobitak 4,7 odsto uz 63
flipflopa po strani, ali jedna od četiri konfiguracije je lošija za 7,1 odsto.

Na petnaest jezgara ne menja ništa: 222,47 naspram upisanih 222,10 MHz, dakle 0,17
odsto pri šumu alata od 3,4 odsto. Zato četiri višejezgarna reda iz
`aes_gcm_ipsec.csv` nisu ponavljana posle njegovog dodavanja.
