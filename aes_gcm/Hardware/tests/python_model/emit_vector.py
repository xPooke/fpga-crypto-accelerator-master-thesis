#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# Company  : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer : Marko Gavrilović
# Email    : markog0403@gmail.com
#
# Emits a golden vector from the software model, in the form the RTL known-answer
# testbenches read: two hex lines, the ciphertext then the tag.
#
# This is what lets the hardware be checked against the model.
#
# Caller, with its own testbench constants:
#
#   ./check_vs_fpga.sh                AES, 16 B bypass, the NIST key
#                                     -> tb_gcm_kat_len
#
# The packet is BYPASS || AAD || PT, filled with the pattern (i*7 + 13) mod 256.
#
#   emit_vector.py <AES> <BYPASS_BYTES> <AAD_BYTES> <PT_BYTES> <out_file>
# ---------------------------------------------------------------------------
import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'Software' / 'Python'))
import gcm_ref as G                                                    # noqa: E402

# The key the testbench drives (NIST SP 800-38D).
KEYS = {
    'AES': bytes.fromhex('feffe9928665731c6d6a8f9467308308'
                         'feffe9928665731c6d6a8f9467308308'),   # tb_gcm_kat_len
}

J0 = bytes.fromhex('cafebabefacedbaddecaf88800000001')


def main():
    if len(sys.argv) != 6:
        sys.exit('usage: emit_vector.py <AES> <BYPASS> <AAD> <PT> <out_file>')
    name, byp, aad_n, pt_n, out = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                                   int(sys.argv[4]), sys.argv[5])

    alg = importlib.import_module(G.ALGORITHMS[name])

    G.BYPASS_BYTES, G.AAD_BYTES = byp, aad_n
    stream = bytes((i * 7 + 13) % 256 for i in range(byp + aad_n + pt_n))

    rk = alg.expand_key(KEYS[name][:alg.KEY_BITS // 8])
    packet = G.encrypt(alg, rk, J0, stream)

    ct = packet[byp + aad_n:len(packet) - G.TAG_BYTES]
    icv = packet[len(packet) - G.TAG_BYTES:]

    with open(out, 'w') as f:
        f.write(ct.hex() + '\n')
        f.write(icv.hex() + '\n')


if __name__ == '__main__':
    main()
