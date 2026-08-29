# ecdh_axis_ip — AXI-Stream omotač ECDH jezgra (top-level IP)

**RTL:** `src/ecdh_axis_ip.vhd` · **Slike:** `ecdh_axis_ip_fsm.svg`
(struktura + FSM), `../../figures/ecdh_axis_ip.svg` (tok podataka + formati)
· **Verifikacija:** `tb_ecdh_axis_ip` — GF(2⁴) **ALL 168 PASS** za
DW ∈ {8,16,32,64} (KEYGEN + SHARED × 6 backpressure parova, provera da
neaktivni izlaz ćuti); B-571 **ALL 4 PASS** (D=32, DW=32)

## Posao (tri rečenice)

1. **Tanki orkestrator** — ne računa ništa: veže `ecdh_deserializer` (paket →
   operandi), `ecdh_top` (k·P → afino) i `ecdh_serializer` ((x,y) → stream),
   plus dva latch-a (`r_k` za skalar, `r_shared` za komandu).
2. Privatni skalar **k stiže side-band-om** (`i_k` + strob `i_k_valid`, obrazac
   AES `i_key/i_key_valid`) i pamti se do reseta — isti k služi i KEYGEN i
   SHARED; k **nikad ne prolazi kroz stream/PS/DMA**.
3. **Jedna operacija u letu**: dok traje (jezgro + slanje), deserijalizator ne
   prima nov paket (`i_ready=0` van `S_IDLE`) — sledeći paket čeka na
   magistrali (backpressure).

## Komande — šta se računa i kuda rezultat ide

Obe komande su ISTA matematika (k·P); razlikuju se po tački koja ulazi i po
značenju/rutiranju rezultata:

| | KEYGEN (`cmd(0)=0`) | SHARED (`cmd(0)=1`) |
|---|---|---|
| Ulazna tačka u paketu | G (generator krive) | Q_tuđ (tuđ javni ključ) |
| Račun | k·G | k·Q_tuđ |
| Rezultat znači | moj javni ključ Q | deljena tajna |
| Šalje se | **x ‖ y** (cela tačka, 2N reči) | **samo x(S)** (N reči) |
| Izlaz → odredište | `m_axis` → **PS** → mreža | `m_axis_z` → **KMAC/SHA3** u PL |
| Tajnost | javno | tajno — nikad u PS |

Deljena tajna je ista na obe strane: `k_A·(k_B·G) = k_B·(k_A·G)`; po ECDH
konvenciji tajna je samo x-koordinata (y ne nosi dodatnu tajnost).

## Interfejs

Generici: `G_M`, `G_D`, `G_F` (prosleđuju se jezgru), **`G_B`** (parametar
krive b, G_M bitova — kriva je fiksna u sintezi; normalizovan kopijom `c_B`),
**`DATA_WIDTH`** ∈ {8,16,32,64}.

| Port | Smer | Opis |
|---|---|---|
| `i_clk`, `i_resetn` | in | takt + sinhroni active-low reset |
| `i_k[G_M-1:0]`, `i_k_valid` | in | side-band skalar; latch na strob, pamti se do reseta |
| `s_axis_t{valid,ready,data,keep,last}` | slave | ulazni paket `cmd ‖ Qx ‖ Qy` (2N+1 reči; format: `ecdh_deserializer.md`) |
| `m_axis_t{valid,ready,data,keep,last}` | master | JAVNI rezultat (KEYGEN) |
| `m_axis_z_t{valid,ready,data,keep,last}` | master | TAJNA x(S) (SHARED) → SHA3 |

## Mašina stanja

| Stanje | Šta radi | Izlaz iz stanja |
|---|---|---|
| `S_IDLE` | jedino stanje u kom deserijalizator prima (`i_ready=1`); na `des.o_valid` lečuje `r_shared ⇐ cmd(0)` | k učitan → `S_CORE`; nije → `S_WAIT_K` |
| `S_WAIT_K` | paket spreman, čeka `i_k_valid` strob (des u `S_WAIT` drži operande) | `r_k_loaded` → `S_CORE` |
| `S_CORE` | jezgro računa k·P (start strob gejtovan na busy) | `core.o_done` → `S_SER` |
| `S_SER` | serijalizator šalje rezultat na izlaz izabran komandom | `ser.o_done` → `S_IDLE` |

Primopredaja paketa je garantovana po konstrukciji: poslednja reč paketa može
biti prihvaćena samo dok je omotač u `S_IDLE`, pa `des.o_valid` uvek zatiče
omotač spreman (detalji: `ecdh_deserializer.md`).

## Tipičan tok upotrebe (softver / TB)

1. Generiši k (RNG) i strobuj `i_k_valid` — jednom, važi za obe komande.
2. Pošalji paket `KEYGEN ‖ G ‖ G` → javni ključ (x‖y) izlazi na `m_axis` → mreža.
3. Primi tuđ javni ključ sa mreže (kroz PS).
4. Pošalji paket `SHARED ‖ Q_tuđ` → x(S) izlazi na `m_axis_z` pravo u KMAC →
   KDF → ključevi za AES-GCM. PS ne vidi ništa tajno.

Paket koji stigne pre k-a nije greška — čeka u `S_WAIT_K`.

## Bezbednosni model (teza §4.5)

- k side-band + tajna samo na `m_axis_z` ⇒ **ni privatni skalar ni sirova
  tajna nikad ne postoje u PS-u** niti u registru čitljivom iz softvera.
- KMAC ugovor: KDF hešira tačno N reči little-endian redosleda (B-571/DW=32:
  72 B, 5 pad bitova nula uključeno) — mora se poklopiti sa softverskom
  stranom protokola.
- Curenje bitlen(k) kroz ukupno vreme: nasleđeno od lestvice, prihvatljivo za
  ECDH (vidi `SPEC_ec_scalar_mult.md`, Bezbednosna beleška).

## Preduslovi i napomene

- Preduslovi jezgra (proverava softver): `k ≥ 1`, `xb ≠ 0`, `k ≠ red(P)−1`
  (inače rezultat đubre; ništa ne visi). Validacija javnog ključa je
  softverova (teza §4.6).
- Ulazni TKEEP se ignoriše; izlazni je uvek sve jedinice.
- IP packaging (predstoji): Vivado prepoznaje AXIS klok po imenu `*aclk` —
  za `i_clk` će trebati `X_INTERFACE_INFO` atributi pri pakovanju.
