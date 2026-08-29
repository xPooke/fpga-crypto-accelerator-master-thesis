# SPEC: `ec_cswap` — constant-time uslovna zamena tačaka

**Fajl:** `src/ec_cswap.vhd` · **Sloj:** EC (iznad `gf_alu`) · **Teorija:** `Rad_cswap_ladder.md`

## Namena

Uslovno zameni radne tačke lestvice P1=(X1,Z1) i P2=(X2,Z2) na osnovu bita skalara,
**bez grananja** — mask + XOR, pa je tok podataka identičan za bit=0 i bit=1
(otpornost na timing/SPA bočni kanal). Ovo je HW verzija tvoje Python funkcije
`cswap` (`ec_ladder.py`), samo što odjednom menja ceo par tačaka (4 vektora).

## Interfejs

Čisto **kombinaciono** (kao `gf_add`) — registrovanje prepušta potrošaču
(scalar-mult FSM), koji ga koristi dva puta po bitu (pre i posle koraka).

| Port | Smer | Tip | Opis |
|---|---|---|---|
| `i_swap` | in | `std_logic` | bit skalara: 1 = zameni, 0 = propusti |
| `i_x1, i_z1` | in | `std_logic_vector(G_M-1 downto 0)` | tačka P1 |
| `i_x2, i_z2` | in | `std_logic_vector(G_M-1 downto 0)` | tačka P2 |
| `o_x1, o_z1` | out | `std_logic_vector(G_M-1 downto 0)` | P1 posle (uslovne) zamene |
| `o_x2, o_z2` | out | `std_logic_vector(G_M-1 downto 0)` | P2 posle (uslovne) zamene |

Generik: `G_M : integer := 4`.

## Ponašanje (šta kod treba da radi)

Za svaki od parova (X1,X2) i (Z1,Z2), po obrascu maska + XOR:

```
mask = (others => i_swap)          -- sve jedinice ili sve nule, m bita
t    = mask and (a xor b)
a'   = a xor t
b'   = b xor t
```

Ukupno: 4 primene istog šablona (x1/x2 i z1/z2 dele isti `t`-princip, ali
svaki par ima svoj `t`). Cena: ~4·m LUT, 1-2 LUT nivoa, nula taktova.

**Zabranjeno:** `if i_swap = '1' then ... else ...` sa različitim mux putevima
po podatku je u redu na FPGA (mux je isto konstantno vreme), ali mask+XOR
oblik zadržavamo jer 1:1 prati Python model i tekst teze.

## Verifikacija

- TB `tb_ec_cswap.vhd`: iscrpno GF(2⁴) po parovima + oba bita; B-571 uzorci.
- Referenca: `ec_ladder.cswap` (dva poziva — jedan za X par, jedan za Z par).
