# ecdh_serializer — paralelno (x, y) → AXI-Stream master

**RTL:** `src/ecdh_serializer.vhd` · **Slika:** `ecdh_serializer.svg`
· **Verifikacija:** kroz `tb_ecdh_axis_ip` (GF(2⁴) ALL 168, uklj. 6 backpressure
parova; B-571 ALL 4 @ DW=32)

## Posao (tri rečenice)

1. Na `i_start` slika rezultat u izlazni šift-registar `r_out` (2N reči):
   `x` u donjih N reči uvek, `y` u gornjih N **samo za KEYGEN**; istovremeno
   lečuje komandu (`r_shared ⇐ i_shared`).
2. Šalje reč po reč sa dna registra (`r_out(DW−1..0)`), a posle svake
   prihvaćene reči šiftuje udesno za jednu reč; reč **stoji stabilna dok
   aktivni `tready` ne dođe** (backpressure).
3. Komanda bira KOJI izlaz govori: KEYGEN → `m_axis` (javno, `x‖y`, 2N reči);
   SHARED → `m_axis_z` (tajna, samo `x`, N reči). **Neaktivni izlaz ćuti**
   (`tvalid=0`) — tajna je nevidljiva javnom putu i obrnuto.

## Interfejs

Generici: `G_M`, `DATA_WIDTH`.

| Port | Smer | Opis |
|---|---|---|
| `i_clk`, `i_resetn` | in | takt + sinhroni active-low reset |
| `i_start` | in | puls: počni slanje (uzorkuje x, y, shared) |
| `i_shared` | in | 0 = KEYGEN (x‖y → `m_axis`), 1 = SHARED (x → `m_axis_z`) |
| `i_x`, `i_y` | in | afino k·P iz jezgra |
| `o_busy`, `o_done` | out | busy nivo; done = 1-takt puls kad je poslednja reč prihvaćena |
| `m_axis_t{valid,ready,data,keep,last}` | master | javni rezultat (KEYGEN) |
| `m_axis_z_t{valid,ready,data,keep,last}` | master | tajna x(S) (SHARED) → pravo u SHA3 |

Izlazni format: LSB-reč-prva (isti kao ulazni paket), TLAST na poslednjoj
reči, TKEEP = sve jedinice (rezultat je uvek ceo broj reči; gornja delimična
reč zero-pad). B-571/DW=32: KEYGEN 36 reči, SHARED 18 reči = 72 B.

## Datapath

- `r_out` (2N reči): napuni se kroz promenljivu na `i_start` (pouzdanije od
  slice-override na signalu), pa se troši šiftovanjem — poslata donja reč
  ispada, nula ulazi sa vrha.
- Pomoćni signali: `w_nwords` = N (SHARED) / 2N (KEYGEN); `w_tready` = tready
  AKTIVNOG izlaza; `w_last` = (`r_cnt` = `w_nwords`−1).
- `r_cnt` broji poslate reči; na poslednjoj reči se NE inkrementira — time
  `w_last` ostaje 1 sve dok potrošač ne prihvati poslednju reč.
- `tdata` se grana na OBA izlaza (isti biti); razdvajanje je isključivo preko
  `tvalid`/`tlast` u `p_COMB_MASTER` — mux po `r_shared`.

## Mašina stanja

| Stanje | Šta radi | Izlaz iz stanja |
|---|---|---|
| `S_IDLE` | čeka `i_start` od omotača; na start puni `r_out` + lečuje komandu | `i_start` → `S_SEND` |
| `S_SEND` | drži `tvalid=1` na aktivnom izlazu; šift na svaki `w_tready` | `w_tready ∧ w_last` → `S_IDLE` (+ `o_done` puls) |

Self-petlja u `S_SEND`: `w_tready ∧ ¬w_last` → šift + `r_cnt+1`. Bez
`w_tready` sve stoji (reč, brojač, stanje) — čist AXIS backpressure.

## Bezbednosna napomena (teza §4.5)

SHARED rezultat postoji SAMO na `m_axis_z` (žica ka SHA3/KMAC u PL-u);
`m_axis` tada ne pulsira nijedan takt. U kombinaciji sa k side-band ulazom
omotača: ni privatni skalar ni sirova tajna nikad ne prolaze kroz PS.
