# gf_add — GF(2^m) sabiranje (kombinaciono)

**RTL:** `src/gf_add.vhd` · **Teorija:** `Ucenje_ECDH.md`, Lekcija 1
· **Verifikacija:** iscrpno GF(2⁴) ALL 256 PASS (+ kroz sve više slojeve)

## Posao

U polju karakteristike 2 je sabiranje = oduzimanje = **XOR po bitu**
(koeficijenti mod 2, bez prenosa — bitovi su koeficijenti polinoma, ne cifre
broja). Hardver: m nezavisnih XOR kapija, 1 LUT nivo bez obzira na m,
konstantno vreme. Sabiranju ne treba redukcija (stepen ostaje < m).

Bez registra — registrovanje radi potrošač (ALU).

## Interfejs

Generik: `G_M`. `i_a, i_b → o_sum`. Nema takta, reseta, handshake-a.

## Napomena

Zbog cene (~m LUT) se u ALU-u **ne deli nego replicira** gde treba — mux koji
bi ga delio košta isto koliko i sam blok (ekonomija deljenja: `gf_alu.md`).
