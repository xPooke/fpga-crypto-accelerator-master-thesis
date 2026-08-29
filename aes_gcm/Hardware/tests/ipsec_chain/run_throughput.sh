#!/usr/bin/env bash
#-----------------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Create Date   : August 2026
# Script Name   : run_throughput.sh
# Tool Version  : Vivado Simulator 2025.1 (xvhdl -2008 / xelab / xsim)
#
# Description   : Cycle-accurate throughput measurement of the full IPsec IP
#                 (ipsec_gcm_enc_top, optionally chained into ipsec_gcm_dec_top)
#                 over a stream of real-size packets: 34 bypass + 16 AAD +
#                 PT_BYTES payload per packet, one key for the whole stream,
#                 IV incremented per packet. Runs tb_ipsec_throughput for every
#                 wrapper kind in KINDS, at every packet count in NPKTS_LIST
#                 (two counts give the steady-state cycles per packet by
#                 differencing: (T2-T1)/(N2-N1)), plus one enc->dec chain run
#                 per kind that proves round-trip and per-packet tag
#                 verification on the same stimulus.
#
#                 One xsim process at a time; all artefacts live in a temporary
#                 directory outside the repo. The CSV lines the testbench
#                 prints are collected and a per-packet summary is derived at
#                 the end. CSV columns:
#                   1 CSV, 2 kind, 3 cores, 4 mult, 5 round, 6 chain, 7 npkts,
#                   8 pt_bytes, 9 in_beats, 10 cycles, 11 out_beats,
#                   12 out_bytes, 13 enc_cycles, 14 enc_beats, 15 enc_bytes,
#                   16 auth_ok, 17 errors
#
# Usage         : ./run_throughput.sh
#                 Environment overrides:
#                   KINDS="MULTICORE UNROLLED"   wrapper kinds to measure
#                   NPKTS_LIST="8 64"            packet counts (>=2 values for
#                                                the differencing step)
#                   CHAIN_NPKTS=8                packets in the chain run
#                                                (0 skips the chain runs)
#                   NUM_CORES=15  MULT_CYCLES=1  ROUND_STYLE=LUT  AES_BITS=256
#                   PT_BYTES=1504                payload bytes per packet
#
# Notes         : Everything is analysed straight out of ../../ip_cores and
#                 ../../synth_tops, the same file list as run_tests.sh, so the
#                 measurement covers the packaged cores and the measured tops.
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

KINDS="${KINDS:-MULTICORE UNROLLED}"
NPKTS_LIST="${NPKTS_LIST:-8 64}"
CHAIN_NPKTS="${CHAIN_NPKTS:-8}"
NUM_CORES="${NUM_CORES:-15}"
MULT_CYCLES="${MULT_CYCLES:-1}"
ROUND_STYLE="${ROUND_STYLE:-LUT}"
AES_BITS="${AES_BITS:-256}"
PT_BYTES="${PT_BYTES:-1504}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

CSV_ALL="$WORK/results_all.csv"
: > "$CSV_ALL"

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
    "$HERE/tb/tb_ipsec_throughput.vhd" > xvhdl.out 2>&1 || { echo "!! analysis failed"; tail -30 xvhdl.out; exit 1; }

# One measurement run: elaborate + simulate one (kind, npkts, chain) point,
# echo the testbench summary and collect the CSV line.
run_one () {
    local kind="$1" npkts="$2" chain="$3"
    local snap="tp_${kind}_${npkts}_${chain}"

    echo
    echo "== ${kind}  packets=${npkts}  chain=${chain}  (cores=${NUM_CORES}, mult=${MULT_CYCLES}, PT=${PT_BYTES} B) =="
    xelab -O3 --nolog work.tb_ipsec_throughput -s "$snap" \
        -generic_top "G_WRAPPER_KIND=$kind" \
        -generic_top "G_NUM_CORES=$NUM_CORES" \
        -generic_top "G_MULT_CYCLES=$MULT_CYCLES" \
        -generic_top "G_ROUND_STYLE=$ROUND_STYLE" \
        -generic_top "G_AES_BITS=$AES_BITS" \
        -generic_top "G_PT_BYTES=$PT_BYTES" \
        -generic_top "G_NUM_PACKETS=$npkts" \
        -generic_top "G_CHAIN=$chain" > "xelab_$snap.out" 2>&1
    if [ $? -ne 0 ]; then
        echo "FAIL(elab)  $snap"
        tail -15 "xelab_$snap.out"
        return 1
    fi

    local out
    out=$(timeout 3600 xsim "$snap" --nolog -runall 2>&1)
    echo "$out" > "xsim_$snap.out"
    echo "$out" | grep -E "config|packet |cycles|in beats|out  |payload|wire|auth|RESULT" | sed 's/^/    /'
    echo "$out" | grep "^CSV," >> "$CSV_ALL"
    rm -rf "$snap" "xsim.dir/$snap"

    if echo "$out" | grep -q "RESULT: PASS"; then
        return 0
    else
        echo "FAIL  $snap"
        echo "$out" | grep -E "LENGTH|HEADER|ROUND-TRIP|CT looks|ICV|timeout|Fatal|Error" | head -5 | sed 's/^/      /'
        return 1
    fi
}

pass=0
fail=0
for kind in $KINDS; do
    for n in $NPKTS_LIST; do
        if run_one "$kind" "$n" 0; then pass=$((pass+1)); else fail=$((fail+1)); fi
    done
    if [ "$CHAIN_NPKTS" -gt 0 ]; then
        if run_one "$kind" "$CHAIN_NPKTS" 1; then pass=$((pass+1)); else fail=$((fail+1)); fi
    fi
done

echo
echo "== raw CSV lines =="
cat "$CSV_ALL"

# Steady-state derivation per wrapper kind from the two enc-only packet counts:
# cycles/packet = (T2-T1)/(N2-N1); overhead = that minus the larger of the
# per-packet input and output beat counts (the stream the IP is bound by).
echo
echo "== derived (steady-state rhythm per wrapper kind) =="
awk -F, '
$1 == "CSV" && $6 == 0 {
    kind = $2; n = $7; cyc = $10;
    if (!(kind in n1))       { n1[kind] = n; t1[kind] = cyc;
                               ib[kind] = $9 / n; ob[kind] = $11 / n; }
    else if (n != n1[kind])  { n2[kind] = n; t2[kind] = cyc; }
}
END {
    for (k in n2) {
        dpp = (t2[k] - t1[k]) / (n2[k] - n1[k]);
        printf "%-10s  cycles/packet = %.2f   input words/packet = %d   output words/packet = %d   overhead = %.2f cycles\n",
               k, dpp, ib[k], ob[k], dpp - ob[k];
    }
}' "$CSV_ALL"

echo
echo "-------------------------------------------"
echo "MEASUREMENTS  TOTAL: $((pass + fail))  PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ] && echo "ALL MEASUREMENTS VALID" || echo "SOME MEASUREMENTS INVALID"
[ "$fail" -eq 0 ]
