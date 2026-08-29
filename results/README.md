# Merni rezultati

Svi brojevi u petom poglavlju rada potiču iz ovih datoteka. Sinteza i
implementacija: Vivado 2025.1, čip `xck26-sfvc784-2LV-c` (Kria KR260),
post-implementaciono, van konteksta, sa taktom kao jedinim ograničenjem.
Merenja propusnosti i latencije su takt-tačna, u simulaciji (GHDL, odnosno
Vivado simulator). Metodologija je opisana u odeljku 5.1 rada.

| Datoteka | Sadržaj |
|---|---|
| `ecdh_synth.csv` | implementacija ECDH jezgra, 15 konfiguracija |
| `ecdh_latencija.csv` | trajanje skalarnog množenja, 16 konfiguracija |
| `ecdh_pretraga.csv`, `ecdh_postsinteza.csv` | radni logovi pretrage učestanosti |
| `ecdh_kriticna_putanja.md` | beleške o kritičnim putanjama ECDH jezgra |
| `sha3_synth.csv` | implementacija SHA-3 jezgra, 14 konfiguracija |
| `sha3_model_bloka.csv` | model cene bloka i provera nad merenjima |
| `sha3_synth_seed.csv`, `sha3_synth_iodelay.csv` | ponovljivost: druga semena i interfejsna ograničenja |
| `aes_synth.csv` | implementacija AES jezgra, 16 prikazanih konfiguracija |
| `ghash_synth.csv`, `ghash_synth_seed.csv` | GHASH jedinica i GCM sloj |
| `aes_gcm_ipsec.csv` | GCM lanac i pun IPsec IP, obe vremenske organizacije |
| `aes_gcm_final.csv` | protočna varijanta kroz ceo put podataka |
| `aes_gcm_ipsec_propusnost.csv` | propusnost celog puta nad paketima realne veličine |
| `gcm_throughput.csv` | takt-tačne serije propusnosti A–D |
| `aes_synth_seed.csv`, `aes_synth_iodelay.csv` | ponovljivost AES merenja |
| `*_stari_omotac.csv` | zatečena merenja pre revizije omotača, čuvana radi sledljivosti |
| `aes_gcm_kriticna_putanja.md` | beleške o kritičnim putanjama AES-GCM puta |
