# tests/l3_full_chain

The whole system: the GCM core **plus** the L3 wrapper that carries the bypass
segment around it. For the core on its own see [`../gcm_core_AES`](../gcm_core_AES).

```bash
./run_tests.sh
```

Everything is analyzed straight out of `../../ip_cores`, so the suite proves the
**packaged cores**, not a private copy of the sources. Current status: **KAT PASS
· KAT-LEN 84/84 · ENC 50/50 · LOOPBACK 50/50 · BYPASS-OFF 25/25**.

---

## What is under test

`src/` holds three test tops that wire the packaged cores together:

| Top | Cores |
|---|---|
| `top_gcm_enc` | 5 — `SPLIT_demux` + `AXIS_full_skid_buffer` + `gcm_enc_glue` + `AES_algorithm` + `MERGE_mux` |
| `top_gcm_dec` | 6 — the same, plus `ICV_realign` |
| `top_gcm_loopback` | 11 — `top_gcm_enc` → `top_gcm_dec` |

`AES_algorithm` has a fixed 128-bit AXIS, so the chain runs at `DATA_WIDTH = 128`.

---

## The suites

| Suite | Testbench | What it proves |
|---|---|---|
| **KAT** | `tb_gcm_kat` | NIST SP 800-38D / McGrew-Viega **test case 4** (AAD = 20 B, PT = 60 B — both partial). CT and tag must match the published vector. |
| **KAT length sweep** | `tb_gcm_kat_len` | Every AAD / PT residue mod 16 (84 combinations) against a software AES-GCM reference (`ref/gen_vectors.py`). |
| **ENC chain** | `tb_top_gcm_enc` | 10 packet geometries × 5 back-pressure profiles. Bypass segment untouched, AAD echoed, CT ‖ ICV appended. |
| **LOOPBACK** | `tb_top_gcm_loopback` | The same, encrypt → decrypt: the packet must round-trip **byte-identical** and the tag must verify. |
| **BYPASS-OFF** | `tb_top_gcm_loopback` | The loopback round-trip with `BYPASS_EN = false`: the packet is AAD ‖ PT with no bypass stream at all. 5 geometries × 5 back-pressure profiles. |

The KAT length sweep is skipped (not failed) if the Python `cryptography` package
is not installed.

---

## Why the KATs lead

The ENC and LOOPBACK sweeps only prove the chain is **self-consistent**. That is a
much weaker claim than it looks: a byte-mirrored stack round-trips perfectly, so a
loopback cannot see a broken byte order — it would simply fail to interoperate
with any other GCM implementation.

Only a known-answer test catches that class of bug, which is why the runner leads
with the KAT and the length sweep. The same blind spot once hid a wrong
`len(A)` in the GHASH lengths block: self-consistent, and silently non-compliant.
