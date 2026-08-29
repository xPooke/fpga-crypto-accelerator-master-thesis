# tests/key_chain

Simulation of the **complete key-derivation-and-use chain** of the thesis
(the chain figure in section 4.5 of the thesis), played out between **two parties**. This
is the one test the per-core suites cannot replace: it proves that each core's
output is accepted **unmodified** at the next core's input, across all three
accelerators.

```bash
./run_tests.sh
```

The suite lives under `aes_gcm/Hardware/tests/` because the AES-GCM tree is
where every other cross-core suite already lives and because the packet
round-trip is the chain's final observable; the ECDH and SHA-3 sources are
analyzed straight out of their own packaged IP trees
(`ecdh/Hardware/ip_cores_ECDH/ECDH/src`, `sha3/Hardware/src`), so the suite
proves the **packaged cores**, not private copies.

---

## The scenario

Side A holds the private scalar `d_A`, side B holds `d_B` (constants in the
generated vector package). Each side has its own ECDH core, its own SHA-3
core, and its own AES-GCM encrypt/decrypt chain.

1. **ECDH (NIST B-571).** Each side runs KEYGEN on its own `ecdh_axis_ip`
   with the standard base point `G`, producing `Q_A = d_A·G` and
   `Q_B = d_B·G` on `m_axis`. The testbench carries the public keys across
   (the only values that travel between the parties) and replays each one,
   exactly as received, into the peer's SHARED operation. The shared secret
   `Z = x(d_A·d_B·G)` appears on `m_axis_z`; both sides must agree and must
   match the `ec_ladder.py` golden model. Public-key validation (checking
   that the received point lies on the curve) is deliberately **not**
   performed here — that discussion belongs to chapter 6 of the thesis.
2. **KMAC256 as KDF (SP 800-56C, thesis example 3.1).** The testbench plays
   the *frame control logic* of the figure: it feeds each SHA-3 core
   (`ALGORITHM = CSHAKE`, cSHAKE256, `L = 256`) the public frame head —
   prefix block (`N = "KMAC"`, `S = "KDF"`) and salt block — then relays the
   18 words of `Z` from `m_axis_z` **word-for-word**, then the tail
   (40 bytes of FixedInfo and `right_encode(256)` in a partial last beat).
   The frame is byte-identical to what `sha3/Hardware/sim/gen_cshake_vectors.py`
   produces; the generator proves that by regenerating the checked-in
   `cshake256_kat_512.txt` byte-for-byte. Both sides must derive the same
   session key `K`, equal to the Python reference.
3. **AES-256-GCM.** Each direction uses one `ipsec_gcm_enc_top` →
   `ipsec_gcm_dec_top` pair (IPsec ESP tunnel geometry: 34 bypass bytes,
   16 AAD bytes). The A→B packet is encrypted with A's derived key and
   decrypted with **B's independently derived key**, and the B→A packet
   (different nonce, different length) the other way around — so the
   round-trip can only succeed if the two derivations agree. A wire monitor
   additionally checks the protected packet on the wire against the
   AES-256-GCM reference (`cryptography` package), and the decryptor's
   `o_auth_ok` must assert.

Pass criterion: every hand-off accepted unmodified, both sides
agree on `Z` and `K`, both match the Python references, and the session key
successfully encrypts and decrypts a packet in each direction (byte-identical
round-trip plus tag verification).

---

## Files

| File | Role |
|---|---|
| `tb/tb_key_chain.vhd` | The chain testbench: two ECDH cores, two SHA-3 cores, two GCM enc/dec pairs, one sequential scenario |
| `tb/tb_key_chain_vectors_pkg.vhd` | **Generated** golden constants — do not edit, regenerate |
| `ref/gen_key_chain_vectors.py` | Golden-value generator; validates its Keccak core against `hashlib`, its framing against the SHA-3 KAT vectors, and the B-571 constants against the curve equation before emitting |
| `run_tests.sh` | xsim harness (xvhdl -2008 → xelab → xsim in a temp dir) |

Regenerating the package (only needed if the scenario constants change):

```bash
cd ref && python3 gen_key_chain_vectors.py
```

---

## Configuration

Defaults are chosen for a functional demonstration, not performance:

| Knob | Default | Why |
|---|---|---|
| `ECDH_D` | 64 | digit width; with the low-latency core one `kP` is 16 326 cycles, the fastest measured configuration |
| `ECDH_LOW_LAT` | `true` | `ecdh_core_low_latency` (three multipliers, parallel step) |
| `NUM_CORES` | 4 | AES `MULTICORE` size — throughput plays no role here, a light wrapper keeps four GCM chains cheap to simulate |
| `MULT_CYCLES` | 1 | single-cycle GHASH multiply, the measured operating point |

All four are environment variables of `run_tests.sh` and generics of the
testbench. Streams run without random backpressure: each core's own suite
(`tb_ecdh_axis_ip`, the SHA-3 KAT sweep, `ipsec_chain`) already proves
handshake robustness, and repeating that here would only obscure the chain
story. For the same reason the ECDH output-silence monitor (secret port quiet
during KEYGEN and vice versa) is not repeated here — `tb_ecdh_axis_ip` owns it.

## Status

PASS (both directions, all golden comparisons), Vivado Simulator 2025.1,
about 36k clock cycles end to end — see `TOTAL CYCLES` in the run log.
