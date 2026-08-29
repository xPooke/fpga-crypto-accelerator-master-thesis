#!/usr/bin/env bash
#-----------------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Create Date   : August 2026
# Script Name   : run_tests.sh
# Tool Version  : Vivado Simulator 2025.1 (xvhdl -2008 / xelab / xsim)
#
# Description   : Simulation of the complete key-derivation-and-use chain
#                 (the chain figure in thesis section 4.5) between two parties:
#
#                   ECDH (B-571, two cores) -> KMAC256 as KDF on the SHA-3
#                   core (CSHAKE configuration, frame assembled by the
#                   testbench in the role of the frame control logic) ->
#                   AES-256-GCM (one ipsec enc/dec pair per direction).
#
#                 All three accelerators are compiled from their packaged
#                 sources into one work library, so the suite proves the
#                 shipped cores talk to each other, not private copies.
#                 Golden values come from tb/tb_key_chain_vectors_pkg.vhd,
#                 generated and cross-validated by
#                 ref/gen_key_chain_vectors.py (see that script's header).
#
# Usage         : ./run_tests.sh
#                 Environment knobs (defaults are the documented run):
#                   ECDH_D=64 ECDH_LOW_LAT=true NUM_CORES=4 MULT_CYCLES=1
#
# Notes         : The work library and every xsim artefact live in a
#                 temporary directory, nothing is written into the repo.
#
# Revision      :
#   0.01 - August 2026 - File Created
#-----------------------------------------------------------------------------------
set -u

export XILINX_VIVADO="${XILINX_VIVADO:-/tools/Xilinx/2025.1/Vivado}"
export PATH="$XILINX_VIVADO/bin:$PATH"
for tool in xvhdl xelab xsim; do
    command -v "$tool" >/dev/null 2>&1 || { echo "!! $tool not in PATH ($XILINX_VIVADO/bin)"; exit 1; }
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HW="$(cd "$HERE/../.." && pwd)"                 # aes_gcm/Hardware
ROOT="$(cd "$HW/../.." && pwd)"                 # repo root
IP="$HW/ip_cores"
L3="$IP/L3_WRAPPER_IP_CORES"
TOPS="$HW/synth_tops"
ECDH_SRC="$ROOT/ecdh/Hardware/ip_cores_ECDH/ECDH/src"
SHA3_SRC="$ROOT/sha3/Hardware/src"

ECDH_D="${ECDH_D:-64}"
ECDH_LOW_LAT="${ECDH_LOW_LAT:-true}"
NUM_CORES="${NUM_CORES:-4}"
MULT_CYCLES="${MULT_CYCLES:-1}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

echo "== analyze ($(xvhdl --version 2>&1 | head -1)) =="
xvhdl -2008 -work work \
    "$ECDH_SRC/gf_alu_pkg.vhd" \
    "$ECDH_SRC/gf_add.vhd" \
    "$ECDH_SRC/gf_sqr.vhd" \
    "$ECDH_SRC/gf_mul.vhd" \
    "$ECDH_SRC/gf_inv.vhd" \
    "$ECDH_SRC/gf_alu.vhd" \
    "$ECDH_SRC/ec_cswap.vhd" \
    "$ECDH_SRC/ec_step_mxy.vhd" \
    "$ECDH_SRC/ecdh_core_basic.vhd" \
    "$ECDH_SRC/ec_point_step_par.vhd" \
    "$ECDH_SRC/ec_scalar_mult_par.vhd" \
    "$ECDH_SRC/ec_mxy_batch.vhd" \
    "$ECDH_SRC/ecdh_core_low_latency.vhd" \
    "$ECDH_SRC/ecdh_deserializer.vhd" \
    "$ECDH_SRC/ecdh_serializer.vhd" \
    "$ECDH_SRC/ecdh_axis_ip.vhd" \
    "$SHA3_SRC/keccak_pkg.vhd" \
    "$SHA3_SRC/sha3_input_buffer.vhd" \
    "$SHA3_SRC/keccak_sponge.vhd" \
    "$SHA3_SRC/sha3_output_buffer.vhd" \
    "$SHA3_SRC/sha3_top.vhd" \
    "$SHA3_SRC/sha3_axis_ip.vhd" \
    "$IP/AES_ALGORITHM/src/aes_pkg.vhd" \
    "$IP/AES_ALGORITHM/src/key_expansion.vhd" \
    "$IP/AES_ALGORITHM/src/aes_round_column.vhd" \
    "$IP/AES_ALGORITHM/src/aes_round.vhd" \
    "$IP/AES_ALGORITHM/src/aes_enc_rolled.vhd" \
    "$IP/AES_ALGORITHM/src/aes_enc_pipelined.vhd" \
    "$IP/AES_ALGORITHM/src/AES_multicore_wrapper.vhd" \
    "$IP/AES_ALGORITHM/src/AES_pipelined_wrapper.vhd" \
    "$IP/AES_ALGORITHM/src/AES_algorithm.vhd" \
    "$IP/GCM_GLUE_ENC/src/GF2_karatsuba_16.vhd" \
    "$IP/GCM_GLUE_ENC/src/GF_karatsuba_32.vhd" \
    "$IP/GCM_GLUE_ENC/src/GF_Karatsuba_64.vhd" \
    "$IP/GCM_GLUE_ENC/src/GF2_Karatsuba_128.vhd" \
    "$IP/GCM_GLUE_ENC/src/GF2_Reduction_128.vhd" \
    "$IP/GCM_GLUE_ENC/src/GF_multiplier.vhd" \
    "$IP/GCM_GLUE_ENC/src/GHASH_single.vhd" \
    "$IP/GCM_GLUE_ENC/src/GHASH_pipelined.vhd" \
    "$IP/GCM_GLUE_ENC/src/GHASH.vhd" \
    "$IP/GCM_GLUE_ENC/src/GHASH_wrapper.vhd" \
    "$IP/GCM_GLUE_ENC/src/AXIS_skid_buffer.vhd" \
    "$IP/GCM_GLUE_ENC/src/axis_broadcaster.vhd" \
    "$IP/GCM_GLUE_ENC/src/AXIS_DEMUX.vhd" \
    "$IP/GCM_GLUE_ENC/src/AXIS_GHASH_MUX.vhd" \
    "$IP/GCM_GLUE_ENC/src/AXIS_MUX.vhd" \
    "$IP/GCM_GLUE_ENC/src/Tag_Finalizer.vhd" \
    "$IP/GCM_GLUE_ENC/src/gcm_enc_glue.vhd" \
    "$IP/GCM_GLUE_DEC/src/AXIS_DEMUX_dec.vhd" \
    "$IP/GCM_GLUE_DEC/src/AXIS_MUX_DEC.vhd" \
    "$IP/GCM_GLUE_DEC/src/Tag_Verifier.vhd" \
    "$IP/GCM_GLUE_DEC/src/gcm_dec_glue.vhd" \
    "$L3/SPLIT_demux/src/util_split.vhd" \
    "$L3/SPLIT_demux/src/SPLIT_demux.vhd" \
    "$L3/MERGE_mux/src/util_merge.vhd" \
    "$L3/MERGE_mux/src/MERGE_mux.vhd" \
    "$L3/ICV_realign/src/ICV_realign.vhd" \
    "$L3/AXIS_full_skid_buffer/src/AXIS_full_skid_buffer.vhd" \
    "$TOPS/ipsec_gcm_enc_top.vhd" \
    "$TOPS/ipsec_gcm_dec_top.vhd" \
    "$HERE/tb/tb_key_chain_vectors_pkg.vhd" \
    "$HERE/tb/tb_key_chain.vhd" > xvhdl.out 2>&1 || { echo "!! analysis failed"; tail -30 xvhdl.out; exit 1; }

echo "== elaborate (ECDH_D=$ECDH_D LOW_LAT=$ECDH_LOW_LAT NUM_CORES=$NUM_CORES MULT_CYCLES=$MULT_CYCLES) =="
xelab -O3 --nolog work.tb_key_chain -s key_chain \
    -generic_top "G_ECDH_D=$ECDH_D" \
    -generic_top "G_ECDH_LOW_LAT=$ECDH_LOW_LAT" \
    -generic_top "G_NUM_CORES=$NUM_CORES" \
    -generic_top "G_MULT_CYCLES=$MULT_CYCLES" > xelab.out 2>&1 \
    || { echo "!! elaboration failed"; tail -30 xelab.out; exit 1; }

echo "== simulate =="
out=$(timeout 3600 xsim key_chain --nolog -runall 2>&1)
status=$?
echo "$out" | grep -E "STEP|KEYGEN|SHARED|KDF|PACKET|PROTECTED|TOTAL CYCLES|ALL TESTS|RESULT" \
    | sed 's/^Note: //;s/ Time.*$//'

echo
echo "-------------------------------------------"
if [ $status -eq 0 ] && echo "$out" | grep -q "RESULT: PASS"; then
    echo "CHAIN: PASS"
    exit 0
else
    echo "CHAIN: FAIL"
    echo "$out" | tail -30
    exit 1
fi
