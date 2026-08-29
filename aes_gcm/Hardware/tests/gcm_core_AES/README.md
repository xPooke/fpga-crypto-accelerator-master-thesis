# tests/gcm_core_AES

The GCM core on its own — the cipher and the glue, **without** the L3 wrapper
(`SPLIT_demux` / `MERGE_mux` / `ICV_realign` / skid). For the whole system see
[`../l3_full_chain`](../l3_full_chain).

```bash
./run_tests.sh                 # both wrapper kinds
./run_tests.sh MULTICORE       # or just one
```

Everything is analyzed straight out of `../../ip_cores`, so the suite proves the
**packaged cores**, not a private copy of the sources. Current status:
**51 / 51 PASS** (MULTICORE and UNROLLED).

`_lib/gcm_composites.vhd` wires `gcm_*_glue + AES_algorithm` back into a single
`gcm_enc` / `gcm_dec` entity, so a testbench drives one DUT instead of the split
pair. It also converts the classic interface the suite was written against
(`AES_BITS` key, 96-bit nonce) into what the packaged cores take (256-bit key
slot, 96-bit nonce).

---

## AES core — the cipher wrappers alone

| Testbench | What it proves |
|---|---|
| `tb_aes_mc` | `AES_multicore_wrapper`: key / IV arriving at every moment around the packet-end flush (ONFLUSH / SHADOW / DOUBLE), keystream cross-checked. |
| `tb_aes_pipelined` | The same, against `AES_pipelined_wrapper`. |
| `tb_wrap_keyrace` | `AES_algorithm` **with no glue**, but with the glue's GHASH gate faked as `m_axis_tready <= not o_h_stale`. A freeze here is a *wrapper* property, not a glue one — that is how the key-swap bug was localised. |
| `tb_key_swallow` | A key pulse landing on the exact flush cycle must not be swallowed. |
| `tb_key_idle_race` | A key pulse in the single `S_IDLE` cycle between packets: the next block must not start on half-reloaded round keys, nor be mis-captured as `H`. |
| `tb_key_no_iv` | Mid-packet key **without** a new IV: the IV-reuse guard must silence the core rather than let it encrypt under a reused IV. |
| `tb_iv_before_key` | IV before the first key: remembered, but nothing may run until a key exists. |
| `tb_flush_xcheck_mc` / `_pipe` | Side-band accounting: `o_H_valid` pulses once per **key epoch**, `o_E_k_valid` once per **packet**. |

## GCM core — glue + AES

**Conformance** — the only tests that prove standard compliance:

| Testbench | What it proves |
|---|---|
| `tb_gcm_kat` | NIST SP 800-38D, AES-128 (with and without AAD) and AES-256. Every CT beat and the ICV bit-exact against the published vector. |
| `tb_gcm_kat_tkeep` | Partial last beats (TKEEP): CT/tag bit-exact, TKEEP passed through, and the captured packet replayed into the decryptor must authenticate. |

**Self-consistency and corner cases:**

| Testbench | What it proves |
|---|---|
| `tb_gcm_enc_src_dense` / `tb_gcm_dec_src_dense` | Dense back-to-back streaming, no idle cycles. |
| `tb_gcm_loopback_src_dense` | Encrypt → decrypt over many packets with periodic rekey (shadow-key path + H gate) and tamper injection; PT scoreboarded, auth verdict must follow the tampering. |
| `tb_dec_malformed` | Truncated / ICV-flipped / over-long packets: auth must reject, no PT may leak, no deadlock. |
| `tb_rekey_on_flush` | A rekey **coincident with `flush_all`** must not deadlock — the cause was the coincidence, not the packet size. |
| `tb_reset_midpacket` | Reset mid-packet: the core recovers and the next packet is bit-exact. |
| `tb_gcm_enc_aes_keyrace` / `tb_gcm_dec_aes_keyrace` | Key-swap **freeze reproducer** through the glue: a key pulse 0–6 cycles after the IV. Offsets 1–4 used to wedge the H gate into a circular deadlock. |

---

## Two things worth knowing

**Conformance vs self-consistency.** Only the KAT testbenches prove the core is
*standard compliant*. Everything else proves it is *self-consistent*, which is a
much weaker claim: a byte-mirrored stack round-trips perfectly and no loopback
can see it. That is exactly the bug class the KATs exist to catch — the vectors
are written in GCM block order and reversed into AXIS order at the DUT boundary,
because the packaged core is an AXIS IP (byte 0 in the LSB lane).

**The H gate.** `H = E(0)` depends on the key, and the GHASH absorb stream is not
data-dependent on it, so under dense traffic the first beats of a packet can
overtake their own `H`. The glue therefore gates GHASH on `o_h_stale` from the
cipher. Getting that gate wrong produced a *circular deadlock* on rekey — hence
the keyrace and `rekey_on_flush` testbenches, and the standalone
`tb_wrap_keyrace` that proves the wrapper (not the glue) was at fault.

`tb_gcm_throughput` in `tb/` is not part of this pass/fail run — the
measurement script `../../../Scripts/sim_gcm_throughput.sh` drives it for the
throughput series.
