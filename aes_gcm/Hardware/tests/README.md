# tests

All suites analyze their sources straight out of `../ip_cores`, so
they prove the **packaged cores** rather than a private copy.

| Suite | Level | Status |
|---|---|---|
| [`gcm_core_AES`](gcm_core_AES) | The GCM core on AES: the cipher and the glue, **without** the L3 wrapper. Cipher-wrapper corner cases, NIST KAT, key-race / rekey / reset, malformed packets. | 51 / 51 PASS (MULTICORE + UNROLLED) |
| [`l3_full_chain`](l3_full_chain) | The whole system: GCM core **plus** `SPLIT_demux`, `MERGE_mux`, `ICV_realign` and the skid buffer. | KAT PASS · KAT-LEN 84/84 · ENC 50/50 · LOOPBACK 50/50 · BYPASS-OFF 25/25 |
| [`ipsec_chain`](ipsec_chain) | The two synthesis tops that `Scripts/synth_gcm_ipsec.tcl` measures: `l3_full_chain` plus three skid buffers per side and the `MULT_CYCLES` generic. Round-trip at both GHASH tempos. | 120 / 120 PASS |
| [`key_chain`](key_chain) | The thesis' complete key-derivation-and-use chain, played out between two parties: ECDH → KMAC (SHA-3) → AES-GCM, sources straight out of all three packaged IP trees. | PASS |
| [`python_model`](python_model) | The software model itself: NIST vector, every residue mod 16 against PyCA `cryptography`, ENC→DEC round-trip (`selftest.py`), and model-vs-FPGA vector emission (`check_vs_fpga.sh`). | ALL PASS |

```bash
cd gcm_core_AES    && ./run_tests.sh
cd l3_full_chain   && ./run_tests.sh
cd ipsec_chain     && ./run_tests.sh
cd key_chain       && ./run_tests.sh
```

Each L3 wrapper core additionally has its own self-checking regression, run from
inside the core's own `tb/`:

| Core | Runs |
|---|---|
| `SPLIT_demux` | 224 |
| `MERGE_mux` | 264 |
| `ICV_realign` | 220 |
| `AXIS_full_skid_buffer` | 96 |

---

**One thing to keep in mind.** Most of these tests prove **self-consistency** — that
the design agrees with itself. A byte-mirrored stack round-trips through a loopback
perfectly and would still fail against every other implementation on earth, so a
green loopback is a much weaker claim than it looks.

Only the known-answer tests are real evidence:

- **AES** — `tb_gcm_kat`, `tb_gcm_kat_tkeep`, `tb_gcm_kat_len`, against NIST SP
  800-38D and an independent software implementation.
