# ec_cswap — constant-time uslovna zamena tačaka

**RTL:** `src/ec_cswap.vhd` · **Spec:** `../spec/SPEC_ec_cswap.md`
· **Verifikacija:** `tb_ec_cswap`: GF(2⁴) iscrpno **ALL 131072 PASS**
(svi ulazi × oba bita); B-571 šabloni ALL 1142 PASS

## Posao

Uslovna zamena P1=(X1,Z1) ↔ P2=(X2,Z2) po bitu skalara: četiri paralelna
2:1 muxa vođena istim bitom, čisto kombinaciono. Oba ulaza muxa su uvek
vožena, pa su tok podataka i tajming **identični za swap=0 i swap=1** —
constant-time zahtev lestvice (SPA/timing otpornost po bitu).

Bez registra (kao `gf_add`) — registrovanje radi potrošač: `ec_scalar_mult`
ga koristi **dva puta po bitu** (S_SWAP pre koraka, S_RESWAP posle), a KAD se
izlazi upisuju odlučuje FSM lestvice, ne ovaj modul.

## Interfejs

Generik: `G_M`. Ulazi: `i_swap` + `i_x1/z1/x2/z2`; izlazi `o_x1/z1/x2/z2`
(zamenjeni ili isti). Nema takta ni reseta — čista logika.

## Napomena iz istorije

Prva verzija je imala `process(i_swap)` — proces se budio samo na promenu
bita pa su izlazi ostajali bajati na promenu podataka (sim/synth mismatch
zamka). Odatle kućno pravilo: kombinaciono = `process(all)` ili paralelne
dodele (usvojeno u `Coding_style/VHDL_STYLE.md`).
