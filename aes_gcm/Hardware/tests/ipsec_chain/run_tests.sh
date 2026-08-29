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
# Description   : Round-trip regression for the two synthesis tops that
#                 Scripts/synth_gcm_ipsec.tcl measures, ipsec_gcm_enc_top and
#                 ipsec_gcm_dec_top. Those tops are tests/l3_full_chain plus three
#                 skid buffers per side and a MULT_CYCLES generic, so the point of
#                 this suite is narrow and specific:
#
#                   * the added skid buffers are transparent, the packet comes back
#                     byte-identical and the tag verifies
#                   * a single-cycle GHASH multiply works in the full chain, not
#                     only in the GHASH unit on its own
#                   * the IPsec ESP tunnel geometry (34 bypass bytes, 16 AAD bytes)
#                     is handled, including the partial last beat
#
#                 Geometry and back-pressure combinations follow
#                 tests/l3_full_chain/run_tests.sh, so a failure here can be
#                 compared against that suite directly.
#
#                 What this does NOT prove is standard compliance. That is what the
#                 KAT suites in tests/l3_full_chain and tests/gcm_core_AES are for,
#                 and they run against the unmodified chain.
#
# Usage         : ./run_tests.sh
#
# Notes         : Everything is analysed straight out of ../../ip_cores and
#                 ../../synth_tops, so the suite proves the packaged cores and the
#                 measured tops, not a private copy. The work library and every
#                 xsim artefact live in a temporary directory.
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
HW="$(cd "$HERE/../.." && pwd)"
IP="$HW/ip_cores"
L3="$IP/L3_WRAPPER_IP_CORES"
TOPS="$HW/synth_tops"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

echo "== analyze ($(xvhdl --version 2>&1 | head -1)) =="
xvhdl -2008 -work work \
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
    "$HERE/tb/tb_ipsec_gcm_loopback.vhd" > xvhdl.out 2>&1 || { echo "!! analysis failed"; tail -30 xvhdl.out; exit 1; }

# "BYPASS AAD PT" -- the first entry is the IPsec ESP tunnel case that is measured
CONFIGS=(
  "34 16 40"    "34 16 128"  "34 16 1"    "34 16 1408"
  "50 20 40"    "29 20 40"   "96 32 64"   "50 15 69"
  "16 16 128"   "64 16 48"   "33 40 100"  "100 48 200"
)
COMBOS=( "100 100" "50 50" "10 90" "90 10" "10 10" )

# The AES wrapper and the multiply timing come from the environment so that the same
# suite can prove the configurations the synthesis sweep measures without a second
# copy of the file list. Defaults are the measured operating point.
MULTS=( ${MULTS:-1 2} )
WRAPPER_KIND="${WRAPPER_KIND:-MULTICORE}"
NUM_CORES="${NUM_CORES:-15}"
ROUND_STYLE="${ROUND_STYLE:-LUT}"
echo "== wrapper: $WRAPPER_KIND  cores: $NUM_CORES  round: $ROUND_STYLE  mult: ${MULTS[*]} =="

# xsim fixes generics at elaboration time, so every geometry needs its own
# snapshot. Elaboration dominates the run time, not simulation.
pass=0
fail=0
for mc in "${MULTS[@]}"; do
    echo
    echo "== round-trip, MULT_CYCLES=$mc =="
    for cfg in "${CONFIGS[@]}"; do
        read -r BYP AAD PT <<< "$cfg"
        for cmb in "${COMBOS[@]}"; do
            read -r PV PR <<< "$cmb"
            snap="lb_${mc}_${BYP}_${AAD}_${PT}_${PV}_${PR}"
            xelab -O3 --nolog work.tb_ipsec_gcm_loopback -s "$snap" \
                -generic_top "MULT_CYCLES=$mc" \
                -generic_top "WRAPPER_KIND=$WRAPPER_KIND" \
                -generic_top "NUM_CORES=$NUM_CORES" \
                -generic_top "ROUND_STYLE=$ROUND_STYLE" \
                -generic_top "BYPASS_BYTES=$BYP" \
                -generic_top "AAD_BYTES=$AAD" \
                -generic_top "PT_BYTES=$PT" \
                -generic_top "P_VALID=$PV" \
                -generic_top "P_READY=$PR" \
                -generic_top "SEED1=$((BYP + PV + 1))" \
                -generic_top "SEED2=$((AAD + PR + 7))" > "xelab_$snap.out" 2>&1
            if [ $? -ne 0 ]; then
                fail=$((fail + 1))
                printf "FAIL(elab)  MC=%s BYP=%s AAD=%s PT=%s PV=%s PR=%s\n" $mc $BYP $AAD $PT $PV $PR
                continue
            fi
            out=$(timeout 900 xsim "$snap" --nolog -runall 2>&1)
            if echo "$out" | grep -q "RESULT: PASS"; then
                pass=$((pass + 1))
            else
                fail=$((fail + 1))
                printf "FAIL  MC=%s BYP=%s AAD=%s PT=%s PV=%s PR=%s\n" $mc $BYP $AAD $PT $PV $PR
                echo "$out" | grep -E "mismatch|LENGTH|AUTH|TLAST|timeout" | head -3 | sed 's/^/      /'
            fi
            rm -rf "$snap" "xsim.dir/$snap"
        done
    done
done

echo
echo "-------------------------------------------"
echo "ROUND-TRIP  TOTAL: $((pass + fail))  PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME TESTS FAILED"
[ "$fail" -eq 0 ]
