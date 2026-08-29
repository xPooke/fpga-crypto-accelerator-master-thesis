# ECDH: zašto post-implementacioni Fmax nije blizu sinteznog

Zabeleženo 2026-08-18, Vivado 2025.1 (SW Build 6140274), part `xck26-sfvc784-2LV-c`.
Merena konfiguracija: `ecdh_f1_d1` — `ecdh_core_basic`, `G_D = 1`, `DATA_WIDTH = 64`.

## Povod

Preliminarna post-sintezna provera pokazala je oko **507 MHz**, pa je
`SEED_MHZ` tabela u `ecdh/Scripts/synth_ecdh_core.tcl` izvedena iz te tačke. Prva dva post-implementaciona prolaza nisu ni prišla toj
vrednosti:

| prolaz | perioda | cilj | WNS | implicirani Fmax |
|---|---|---|---|---|
| 1 | 2,222 ns | 450,0 MHz | −0,476 ns | 370,6 MHz |
| 2 | 2,748 ns | 363,9 MHz | −0,625 ns | 296,5 MHz |

Ta razlika nije šum merenja i ne potiče od pogrešno izabrane konfiguracije.

## Prvo isključeno: nije sintetisano pogrešno jezgro

Izveštaj putanje imenuje izvor kao
`u_dut/gen_low_latency.u_core/u_alu/u_mul/r_a_reg[78]`, što izgleda kao da je
uprkos `G_LOW_LATENCY => false` sintetisano brzo jezgro. Nije: u VHDL-2008
`if … generate / else generate` **labela pokriva obe grane**, pa i `else` grana
nosi ime `gen_low_latency`. Sintezni log to potvrđuje bez dvosmislice:

```
INFO: [Synth 8-638] synthesizing module 'ecdh_core_basic'
```

Zamka je vredna pamćenja: hijerarhijsko ime instance u izveštaju tajminga **ne
dokazuje** koja je grana `if-generate`-a izabrana.

## Najgora putanja

Unutar množača (`gf_alu` → `gf_mul`), registar u registar:

```
Source:      u_dut/…/u_alu/u_mul/r_a_reg[78]/C
Destination: u_dut/…/u_alu/u_mul/r_accumulator_reg[391]/D
```

| stavka | vrednost |
|---|---|
| ukupno kašnjenje puta podataka | 3,368 ns |
| **logika** | **0,951 ns (28,2 %)** |
| **rutiranje** | **2,417 ns (71,8 %)** |
| nivoa logike | 8 (LUT6 × 3, LUT4 × 1, MUXF7 × 2, MUXF8 × 2) |
| zauzeće čipa | 17 467 LUT-ova = **14,91 %** |
| kritičnih krajeva | **1016** od 34 785 |
| raspon smeštaja putanje | `SLICE_X35Y104` → `X45Y112` → `X46Y102` → `X48Y99` → `X52Y100` |

Dve veze nose skoro polovinu putanje:

- **0,792 ns** na vezi fanouta **1** (izlaz `r_a_reg[78]` do prvog LUT6),
- **0,715 ns** na `v_acc1`, fanouta **571** — jedan signal se emituje u ceo
  571-bitni akumulator.

## Zaključak

Jezgro je **ograničeno vezama, a ne logikom**. Sama logika te putanje traje
0,951 ns, što bi odgovaralo učestanosti preko 900 MHz; sve preko toga su žice.
Sinteza je zato i mogla da prijavi ~507 MHz — ona kašnjenje veza procenjuje nad
neraspoređenim dizajnom (`Design State : Synthesized`), dakle meri upravo onu
komponentu koja ovde nije usko grlo.

Nije reč o zagušenju od popunjenog čipa: zauzeće je ispod 15 %. Uzrok je
struktura — 571-bitni operandi se fizički prostiru preko sedamnaest kolona
CLB-ova, a bit-serijski množač taj raspon preseca svakog takta. Podatak da
1016 krajeva ne ispunjava tajming (a ne jedan patološki put) pokazuje da je
pojava sistemska, a ne izuzetak.

**Posledica za metodologiju:** za ovo jezgro post-sinteza nije upotrebljiva ni
kao gruba procena Fmax-a, pa `SEED_MHZ` tabela izvedena iz nje sistematski maši
naviše. Tabela je zato skalirana po izmerenoj tački, a skripta korekciju semena
izričito predviđa (`SYNTH_START_MHZ`).

**Posledica za rad:** brojka po sebi je manje zanimljiva od nalaza. Za peto
poglavlje ovo je argument da se učestanost B-571 jezgra ne može projektovati iz
složenosti logike, jer je kritični put pretežno trasa — i to razlikuje ECDH
jezgro od SHA-3 i AES jezgara, kod kojih rutiranje nije dominantno.

## Potvrda na drugom kraju opsega (D = 128)

`ecdh_f1_d128` je merena posle korekcije semena i daje istu sliku iz drugog ugla:

| prolaz | perioda | WNS posle `place_design` | WNS posle `route_design` | zatvorio |
|---|---|---|---|---|
| 1 | 7,143 ns | **+0,293** | −0,127 | ne |
| 2 | 7,320 ns | **+0,431** | +0,076 | da |
| 3 | 7,290 ns | **+0,473** | +0,095 | da |

Raspoređivanje zatvara tajming sa širokom rezervom u sva tri prolaza, a rutiranje
je svaki put pojede za 0,36 do 0,42 ns. Kod `G_D = 1` raspoređivanje je već bilo
u minusu (−0,494 ns), pa su to dva različita režima istog uzroka: kod uske cifre
kritični put je dugačak zbog rasutosti 571-bitnih vektora, a kod široke ga
rutiranje obara pošto ga je raspoređivanje već rešilo. U oba slučaja
**odluka pada na vezama, ne na logici.**

Izmereni red: Fmax 139,38 MHz, 53 759 LUT-ova, 17 476 FF-ova, 0,781 W, tri
prolaza, WNS 0,115 ns. Pretraga je stala na broju prolaza (0,115 ns je iznad
praga od 0,050 ns), ali razlika od 0,065 ns je ispod izmerenog šuma rasporeda i
rutiranja od oko 0,15 ns, pa ponovno puštanje sa novim semenom ne bi merilo
dizajn nego šum.

## Granica ploče: `ecdh_f2_d128` ne staje

Paralelno jezgro sa `G_D = 128` uopšte ne dolazi do implementacije:

```
ERROR: [DRC UTLZ-1] Resource utilization: LUT as Logic over-utilized
  This design requires 162863 of such cell types but only 117120
  compatible sites are available in the target device.
```

Traži **162 863 LUT-ova**, a `xck26-sfvc784-2LV-c` ima **117 120** — 139 %
raspoloživog. Sinteza prolazi, `place_design` odbija da krene.

Mreža od 16 konfiguracija zato **nije ostvariva u celosti**, i to nije nedostatak
merenja nego nalaz: širinu cifre paralelnog jezgra ograničava kapacitet ploče
pre nego tajming. Pošto zauzeće raste sa `G_D`, prva konfiguracija koja ne stane
povlači i sve šire za sobom, pa prekid ne gubi nijedno ostvarivo merenje.

## Trag u podacima

Istorija pretrage, sa WNS-om posle raspoređivanja i posle rutiranja za **svaki**
prolaz uključujući promašaje, čuva se u `ecdh_pretraga.csv`. `ecdh_synth.csv`
po konstrukciji pamti samo pobednički prolaz, pa promašaji iz njega nestaju.
