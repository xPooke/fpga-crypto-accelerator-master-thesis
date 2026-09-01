# Kriptografski akcelerator na FPGA platformi zasnovan na ECDH, SHA-3 i AES-GCM algoritmima

Master rad — Elektrotehnički fakultet, Univerzitet u Beogradu.
Autor: Marko Gavrilović.

Ceo rad je u datoteci [`Master_rad.pdf`](Master_rad.pdf), a LaTeX izvor u
folderu `thesis/`.

## Šta je realizovano

Tri akceleratorska jezgra u VHDL-u, sa zajedničkim AXI4-Stream interfejsnim
ugovorom, i njihov zajednički lanac za hibridni kriptosistem:

| Jezgro | Uloga | Realizacija |
|---|---|---|
| **ECDH** | razmena ključa nad krivom B-571 | Montgomeryjeve merdevine samo nad x-koordinatom, digit-serijski množač u GF(2^571), osnovno i paralelno jezgro |
| **SHA-3** | heširanje i izvođenje ključeva (cSHAKE/KMAC) | ceo FIPS 202 jednim RTL opisom, dve arhitekture (1 i 2 runde po taktu), drajver za PetaLinux |
| **AES-GCM** | AEAD zaštita saobraćaja (AES-256) | protočna i višejezgarna arhitektura, GHASH sa Karatsubinim množačem, pun IPsec ESP omotač |

Ciljna platforma je Kria KR260 (Zynq UltraScale+, `xck26-sfvc784-2LV-c`).
Lanac razmene, izvođenja i upotrebe ključa proveren je simulacijom sa dve
strane. SHA-3 jezgro je pušteno i na ploči pod PetaLinux sistemom, a AES-GCM
u postojećem mrežnom sistemu.

## Struktura repoa

| Folder | Sadržaj |
|---|---|
| `thesis/` | LaTeX izvor rada |
| `ecdh/`, `sha3/`, `aes_gcm/` | po jezgru: `Hardware/` (zapakovana IP jezgra, RTL, testbenčevi), `Scripts/` (sinteza i merenja), `Software/` (referentni modeli, kod SHA-3 i drajver) |
| `results/` | merni CSV-ovi iz kojih potiču sve brojke u radu |
| `presentation/` | prezentacija javne odbrane rada |

## Provere i merenja

Funkcionalne provere (GHDL, `--std=08 -fsynopsys`):

```bash
bash sha3/Hardware/sim/run_kat_sweep.sh          # SHA-3: KAT + granični slučajevi
bash aes_gcm/Hardware/tests/gcm_core_AES/run_tests.sh   # AES-GCM: jezgro i omotači
bash aes_gcm/Hardware/tests/l3_full_chain/run_tests.sh  # AES-GCM: ceo lanac
```

ECDH provere su vektorski testovi po nivoima, od množača u polju do celog
IP jezgra. Vektore generišu skripte `gen_*_vectors.py` iz referentnog modela
`gf2m.py` (`ecdh/Software/Python/`), a komanda za pokretanje svakog
testbencha data je u njegovom zaglavlju (`ecdh/Hardware/ip_cores_ECDH/ECDH/sim/`).
Isti model proverava i svaki prolaz merenja latencije.

Sinteza i merenja (Vivado 2025.1, post-implementaciono, van konteksta) rade
se skriptama `synth_*.tcl` u `Scripts/` folderima. Propusnost mere
`sha3/Scripts/sim_sha3_throughput.sh` i `aes_gcm/Scripts/sim_gcm_throughput.sh`,
a latenciju skalarnog množenja `sim_ecdh_latencija.sh`.
Referentni modeli u Python-u nezavisno računaju iste funkcije i izvor su
svih vektora.

Kod i komentari su na engleskom, rad je na srpskom jeziku.
