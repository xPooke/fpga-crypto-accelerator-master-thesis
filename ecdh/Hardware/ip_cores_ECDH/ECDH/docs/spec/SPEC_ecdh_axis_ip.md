# SPEC: `ecdh_axis_ip` — AXI-Stream omotač ECDH jezgra

**Obrazac:** `sha3_axis_ip` (cela teza je AXIS; AXI-Lite ne postoji nigde).
**Sastav:** 3 celine — `ecdh_deserializer` (paket → operandi), `ecdh_top`
(k·P → afino), `ecdh_serializer` ((x,y) → stream + rutiranje). Slike:
`figures/ecdh_sistem.svg` (nivo 1), `ecdh_axis_ip.svg` (nivo 2).

## Namena i bezbednosni model

- **Privatni skalar k = side-band** (`i_k` + strob `i_k_valid`, obrazac AES
  `i_key/i_key_valid`) — k NIKAD ne prolazi kroz stream/PS/DMA.
- **Tajna x(S) (SHARED) → poseban `m_axis_z`** izlaz, žicom pravo u SHA3
  `s_axis` u PL-u; **javni rezultat (KEYGEN) → `m_axis`**. Neaktivni izlaz
  ćuti (`tvalid=0`) — tajna nije vidljiva ni PS-u ni javnom putu (teza §4.5).
- Curenje bitlen(k) kroz vreme: vidi `SPEC_ec_scalar_mult.md`, Bezbednosna
  beleška. Validacija javnog ključa Q je softverova (teza §4.6).

## Interfejs

Generici: `G_M`, `G_D`, `G_F` (kao jezgro), **`G_B`** (parametar krive —
omotač ga vezuje na `i_b` jezgra; G_M bitova), **`DATA_WIDTH`** ∈ {8,16,32,64}.

| Port | Smer | Opis |
|---|---|---|
| `i_clk`, `i_resetn` | in | takt + active-low reset |
| `i_k[G_M-1:0]`, `i_k_valid` | in | side-band skalar; latch na strob, pamti se do reseta |
| `s_axis_t{valid,ready,data,keep,last}` | slave | ulazni paket `cmd ‖ Qx ‖ Qy` |
| `m_axis_t{valid,ready,data,keep,last}` | master | JAVNI rezultat (KEYGEN: `x ‖ y`) |
| `m_axis_z_t{valid,ready,data,keep,last}` | master | TAJNA (SHARED: `x`) → SHA3 |

## Format paketa (N = ⌈G_M/DATA_WIDTH⌉ reči po polju)

- **Ulaz** (`s_axis`): beat 0 = `cmd` (jedna reč; `cmd(0)='1'` → SHARED,
  `'0'` → KEYGEN), beat-ovi 1..N = Qx, N+1..2N = Qy; TLAST na beat-u 2N.
  Ukupno **2N+1 reči** (B-571, DW=32: 37 reči).
- **Pakovanje: LSB-reč-prva** — reč 0 = biti DW−1..0; gornja delimična reč
  zero-pad (B-571, DW=32: 18. reč polja nosi 27 bita + 5 nula).
- **Izlaz:** KEYGEN → `m_axis`: `x ‖ y` = 2N reči; SHARED → `m_axis_z`:
  `x` = N reči (B-571, DW=32: 18 reči = 72 B). TLAST na poslednjoj reči,
  TKEEP = sve jedinice (uvek cele reči). Ulazni TKEEP se IGNORIŠE.
- **Softverski/KMAC ugovor:** KDF hešira tačno tih 72 B little-endian
  redosleda reči (5 pad bitova nula uključeno).
- Rubni paketi: prekratak (TLAST prerano) → tiho odbačen; predugačak →
  `S_DROP` guta do TLAST-a. Nema error signala (namerno tanak omotač).

## FSM omotača i protokol upotrebe

`S_IDLE → (S_WAIT_K) → S_CORE → S_SER → S_IDLE` — jedna operacija u letu;
dok jezgro računa, deserializer ne prima (`s_axis_tready=0` van S_IDLE).

Tipičan tok: (1) softver/PS generiše k i strobuje `i_k_valid` (jednom — isti
k važi za KEYGEN i SHARED); (2) pošalje paket `KEYGEN ‖ G ‖ G` → javni ključ
izađe na `m_axis`; (3) razmena preko mreže; (4) pošalje `SHARED ‖ Q_tuđ` →
x(S) izađe na `m_axis_z` pravo u KMAC. Paket koji stigne pre k-a čeka u
`S_WAIT_K`.

## Verifikacija

- `sim/tb_ecdh_axis_ip.vhd` — paketski TB: šalje pakete, prima na oba
  master porta, proverava da NEAKTIVNI izlaz ćuti; **6 backpressure parova**
  (ulaz%/izlaz%): 100/100, 50/50, 30/70, 70/30, 90/10, 10/90.
- GF(2⁴): **ALL 168 PASS** za DW ∈ {8, 16, 32, 64} (KEYGEN + SHARED).
- B-571 (D=32, DW=32, `ladder_vec_b571_fixedb.txt`, b=1, 2 vektora):
  **ALL 4 PASS** (12.8.2026; backpressure iscrpno pokriven na GF(2⁴)).

<!-- THESIS-SKIP: pocetak bug beleske -->
- 🐞 Bug-priča (12.8, uhvaćena TB-om): deserializer je reč sa TLAST-om samo
  „brojao" a NE pakovao → za DW ≥ G_M cela Qy se gubila → y pogrešan, x tačan
  (x ne zavisi od Qy!). Fix: reč se UVEK pakuje, TLAST samo završava paket.
  Pouka: rub „poslednja reč nosi i podatak i kraj" mora u TB šablone.
<!-- THESIS-SKIP: kraj bug beleske -->

## Napomene

- `ecdh_deserializer`/`ecdh_serializer` su generički AXIS gearbox-evi
  (`G_M`, `DATA_WIDTH`) — kandidati za ponovnu upotrebu.
- IP packaging za Vivado: obrazac `package_sha3_ip.tcl` (predstoji).
