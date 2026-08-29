# Python reference model

A software model of the chain that gives **the same bytes as the FPGA**, for the
same key, IV and input file.

The proofs of that claim live next door, in
[`../../Hardware/tests/python_model`](../../Hardware/tests/python_model) (model vs RTL, and the model
against NIST).

---

## Running it

```
gcm_ref.py [-h] [--in FILE] [--out FILE] [--key FILE] [--iv FILE] {ENC,DEC} {AES}
```

```bash
./gcm_ref.py -h                                       # the full option list
./gcm_ref.py ENC AES                                  # data/in.txt -> data/out.txt
./gcm_ref.py DEC AES --in data/ct.txt --out data/pt.txt
```

| Argument | |
|---|---|
| `ENC` / `DEC` | encrypt + authenticate, or decrypt + verify |
| `AES` | the cipher — **AES-256** |
| `--in FILE` | input packet — default `data/in.txt` |
| `--out FILE` | output packet — default `data/out.txt` |
| `--key FILE` | key blob, MSB first — default `params/key.txt` |
| `--iv FILE` | `J0` = 96-bit nonce ‖ `00000001` — default `params/iv.txt` |

Every file is plain hex text: `#` comments and whitespace are ignored, so a
packet can be written one 16-byte block per line.

**Exit code is 1 if a `DEC` fails to authenticate**, so it can be used in a
script. Nothing is trusted before the tag verifies.

### The packet

```
ENC   BYPASS(16 B) ‖ AAD(20 B) ‖ PT                 →  BYPASS ‖ AAD ‖ CT ‖ ICV(16 B)
DEC   BYPASS(16 B) ‖ AAD(20 B) ‖ CT ‖ ICV(16 B)     →  BYPASS ‖ AAD ‖ PT
```

`BYPASS_BYTES` and `AAD_BYTES` are constants at the top of `gcm_ref.py`, because
they are **compile-time generics in the hardware**. Neither has to be a multiple
of 16 — the partial-block paths are where the interesting bugs live. The payload
length is discovered from the file, as the hardware discovers it from `TLAST`.

`params/key.txt` holds the **256-bit AES key**, exactly as the hardware
gets it on `i_key`.

---

## Files

| | |
|---|---|
| `gcm_ref.py` | The GCM layer and the packet. **Knows nothing about the cipher.** |
| `alg_aes256.py` | AES-256 provider. |
| `params/`, `data/` | Key and `J0`; input and output packet. |

---

## The cipher provider contract

The cipher is a plug-in, exactly as it is in the hardware.
`gcm_ref.py` holds everything that is *not* the cipher — GHASH, the counter, the
lengths block, the tag, the byte order — and imports the rest. A provider module
is all of this:

| | |
|---|---|
| `NAME` | display name |
| `KEY_BITS` | key length in bits |
| `NUM_ROUNDS` | how many times `round` is applied |
| `expand_key(key: bytes) -> list[bytes]` | the round keys, 16 bytes each |
| `round(state: bytes, round_key: bytes) -> bytes` | **one** round, 16 B → 16 B |
| `encrypt_block(block: bytes, round_keys: list) -> bytes` | the only function GCM calls |

A new provider registered in `ALGORITHMS` at the top of `gcm_ref.py` becomes
selectable on the command line.

`round` must be the *same* round every time. AES's last round has no MixColumns,
so that difference lives in `encrypt_block`, not in `round` — and the hardware
draws the same line (`aes_round.vhd` is one main round).

Three things must hold or GCM will be **silently wrong**:

1. `encrypt_block` is a 128→128-bit permutation. GCM uses it for three different
   jobs and cannot tell them apart: `H = E(0)` is the GHASH subkey, `E(J0)` masks
   the tag, and `E(J0+i)` is the keystream.
2. It must **encrypt**, never decrypt — GCM decrypts by XOR-ing the same keystream
   back, so no inverse cipher exists anywhere in the design.
3. Byte 0 of a block is byte 0 of the stream. **Reverse nothing.** The hardware
   reverses at its AXIS port precisely so this holds.
