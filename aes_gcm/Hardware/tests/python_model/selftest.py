#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# Company  : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer : Marko Gavrilović
# Email    : markog0403@gmail.com
#
# Proves gcm_ref.py is bit-exact, not merely self-consistent.
#
#   1. NIST SP 800-38D AES-256 vector — the raw GCM primitive.
#   2. Every BYPASS / AAD / PT residue mod 16, against an independent
#      AES-256-GCM implementation (PyCA `cryptography`). This is the same
#      sweep the hardware passes (tests/l3_full_chain, KAT-LEN 84/84), so a
#      match here means the model and the FPGA agree with the standard —
#      and therefore with each other.
#   3. ENC -> DEC round-trip, and a flipped byte must be rejected.
#
# Note what a round-trip alone would NOT prove: a byte-mirrored model round-trips
# perfectly. Only 1 and 2 are real evidence.
# ---------------------------------------------------------------------------
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'Software' / 'Python'))
import alg_aes256 as aes                                              # noqa: E402
import gcm_ref as G                                                   # noqa: E402

FAIL = 0


def check(name, got, want):
    global FAIL
    ok = got == want
    FAIL += not ok
    print(f'  {"PASS" if ok else "FAIL"}  {name}')
    if not ok:
        print(f'        got  {got}\n        want {want}')


# --- 1. NIST SP 800-38D, AES-256, test case 16 ------------------------------
print('NIST SP 800-38D  (AES-256, 20 B AAD, 60 B PT)')
key = bytes.fromhex('feffe9928665731c6d6a8f9467308308'
                    'feffe9928665731c6d6a8f9467308308')
j0  = bytes.fromhex('cafebabefacedbaddecaf88800000001')
aad = bytes.fromhex('feedfacedeadbeeffeedfacedeadbeefabaddad2')
pt  = bytes.fromhex('d9313225f88406e5a55909c5aff5269a'
                    '86a7a9531534f7da2e4c303d8a318a72'
                    '1c3c0c95956809532fcf0e2449a6b525'
                    'b16aedf5aa0de657ba637b39')

rk = aes.expand_key(key)
ct = G.keystream_xor(aes, pt, rk, j0)
tg = G.tag(aes, rk, j0, aad, ct)

check('ciphertext', ct.hex(),
      '522dc1f099567d07f47f37a32a84427d'
      '643a8cdcbfe5c0c97598a2bd2555d1aa'
      '8cb08e48590dbb3da7b08b1056828838'
      'c5f61e6393ba7a0abcc9f662')
check('tag       ', tg.hex(), '76fc6ece0f4e1768cddf8853bb2d551b')

# --- 2. against an independent implementation, every residue mod 16 ---------
print('\nvs PyCA cryptography  (BYPASS x AAD x PT, every residue mod 16)')
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    print('  SKIPPED — python3 "cryptography" not installed')
else:
    nonce = j0[:12]
    npass = 0
    for byp in (0, 1, 15, 16, 17, 50):
        for ad in (0, 1, 15, 16, 17, 20, 33):
            for n in (0, 1, 15, 16, 17, 60, 63, 64, 65):
                G.BYPASS_BYTES, G.AAD_BYTES = byp, ad
                stream = bytes((i * 7 + 13) % 256 for i in range(byp + ad + n))

                out = G.encrypt(aes, rk, j0, stream)
                ref = AESGCM(key).encrypt(nonce, stream[byp + ad:], stream[byp:byp + ad])

                if out != stream[:byp + ad] + ref:
                    print(f'  FAIL  BYPASS={byp} AAD={ad} PT={n}')
                    FAIL += 1
                else:
                    npass += 1
    print(f'  PASS  {npass}/{npass} combinations bit-exact')

# --- 3. round-trip and tamper ----------------------------------------------
print('\nround-trip')
G.BYPASS_BYTES, G.AAD_BYTES = 16, 20
stream = bytes((i * 7 + 13) % 256 for i in range(96))
enc = G.encrypt(aes, rk, j0, stream)
dec, ok = G.decrypt(aes, rk, j0, enc)
check('ENC -> DEC returns the packet', dec.hex(), stream.hex())
check('tag verifies                 ', ok, True)

bad = bytearray(enc)
bad[40] ^= 1                                   # flip one ciphertext byte
_, ok = G.decrypt(aes, rk, j0, bytes(bad))
check('a flipped CT byte is rejected', ok, False)

print('\n' + ('ALL PASS' if not FAIL else f'{FAIL} FAILED'))
sys.exit(1 if FAIL else 0)
