# ecdh_deserializer — AXIS slave → paralelni operandi

**RTL:** `src/ecdh_deserializer.vhd` · **Slika:** `ecdh_deserializer.svg`
· **Verifikacija:** kroz `tb_ecdh_axis_ip` (GF(2⁴) ALL 168, uklj. 6 backpressure
parova; B-571 ALL 4 @ DW=32)

## Posao (tri rečenice)

1. Prihvati reč sa strima kad je `tvalid ∧ tready`; `tready` postoji samo dok
   omotač kaže da je spreman (`i_ready`) — dok jezgro računa, novi paket **čeka
   na magistrali** (backpressure), ništa se ne gubi.
2. Upiši reč po rednom broju (`r_beat`): beat 0 → `r_cmd`, 1..N → `r_qx`,
   N+1..2N → `r_qy` (N = ⌈G_M/DATA_WIDTH⌉). **I reč koja nosi TLAST se upisuje**
   — TLAST je podatak + kraj, ne samo kraj.
3. Ako je TLAST stigao tačno na beat-u 2N (tačna dužina) → `o_valid` puls
   (1 takt) i omotač preuzima. Svaka druga dužina → paket se **tiho odbacuje**.

## Interfejs

Generici: `G_M` (širina polja), `DATA_WIDTH` (širina stream reči).

| Port | Smer | Opis |
|---|---|---|
| `i_clk`, `i_resetn` | in | takt + sinhroni active-low reset |
| `s_axis_t{valid,ready,data,last}` | slave | ulazni paket; TKEEP se ignoriše (pune reči) |
| `i_ready` | in | omotač spreman za nov paket (= omotač u `S_IDLE`) |
| `o_cmd` | out | prva reč paketa; `cmd(0)`: 1=SHARED, 0=KEYGEN |
| `o_qx`, `o_qy` | out | raspakovana tačka (donjih G_M bita šift-registara) |
| `o_valid` | out | 1-takt puls: paket kompletan, izlazi važe |

Format paketa: `cmd ‖ Qx ‖ Qy` = **2N+1 reči**, LSB-reč-prva (reč 0 = biti
DW−1..0), gornja delimična reč zero-pad. B-571/DW=32: 1+18+18 = 37 reči.

## Mašina stanja

| Stanje | Šta radi | Izlaz iz stanja |
|---|---|---|
| `S_COLLECT` | prima i pakuje reči | vidi scenarije A/B/C dole |
| `S_PRESENT` | `o_valid=1`, tačno 1 takt | uvek → `S_WAIT` |
| `S_WAIT` | drži izlaze zamrznute, ulaz zatvoren, dok traje CELA operacija (jezgro + slanje rezultata) | `i_ready=1` → `S_COLLECT` |
| `S_DROP` | vanredno: prima i baca reči predugačkog paketa | `accept ∧ TLAST` → `S_COLLECT` |

### Tri scenarija dužine paketa

- **A) Tačna dužina** (`TLAST ∧ beat=2N`) → `S_PRESENT`, `o_valid`. ✓
- **B) Prekratak** (`TLAST ∧ beat<2N`) → tiho odbaci: nema `o_valid`, `r_beat=0`,
  ostaje `S_COLLECT`. **Nema gutanja** — TLAST je sam po sebi granica paketa,
  kraj je već viđen. Polupakovane reči niko ne vidi (izlazi „važe" samo od
  `o_valid`) i pregaziće ih sledeći paket.
- **C) Predugačak** (reč posle beat-a 2N bez TLAST) → `S_DROP`: drži `tready=1`
  i prima-pa-baca do TLAST-a. **Mora da guta** jer je granica paketa tek
  ispred, a AXIS nema „prekini" — povratak u `S_COLLECT` bez gutanja bi rep
  paketa protumačio kao `cmd` sledećeg → trajna desinhronizacija framinga.

**Drop = resinhronizacija na granicu paketa, ne kazna.** Greška se ne
signalizira (tanak omotač); pogrešan paket može poslati samo softverska
greška, a manifestuje se kao „nema odgovora" → softverski timeout.

## Garancija primopredaje (zašto je 1-takt `o_valid` dovoljan)

Poslednja reč paketa može biti prihvaćena **isključivo dok je omotač u
`S_IDLE`** (jer `w_accept` zahteva `i_ready`). Zato `o_valid` puls (takt
kasnije) uvek zatiče omotač u `S_IDLE` — istog takta omotač lečuje
`r_shared ⇐ cmd(0)` i prelazi u `S_CORE`/`S_WAIT_K`. Scenario „pulsirao sam,
niko nije slušao" ne postoji po konstrukciji.

## Zašto `S_WAIT` drži izlaze zamrznute

`ecdh_top` dobija `i_xb/i_yb` direktno sa `o_qx/o_qy` žica i snapshotuje ih
tek na svoj start — a on kroz `S_WAIT_K` granu (čeka se `i_k_valid` strob)
može doći proizvoljno kasno. `S_WAIT` garantuje stabilne operande koliko god
to trajalo, i istovremeno brani ulaz (`tready=0`) da novi paket ne pregazi
tekuće operande.

## Napomena (bug-pouka, 12.8.2026)

Prva verzija je reč sa TLAST-om samo „brojala" a nije pakovala → za
DW ≥ G_M cela `Qy` se gubila (y pogrešan, x tačan — x ne zavisi od Qy).
Pouka ugrađena u pravilo #2 gore i u TB šablone.
