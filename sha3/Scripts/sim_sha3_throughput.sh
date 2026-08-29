#!/usr/bin/env bash
# ---------------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Create Date   : August 2026
# Design Name   : sim_sha3_throughput
# Tool Version  : GHDL (--std=08 -fsynopsys)
#
# Description   : Cycle-accurate throughput and latency measurement of the SHA-3
#                 core, the source of results/sha3_model_bloka.csv. Runs
#                 tb_sha3_throughput for every configuration in that table with
#                 G_MSG_BLOCKS = 50 and 400 and records the measured cycle
#                 counts, plus the 16-byte-message latency (the per-derivation
#                 cost of the KDF use case).
#
#                 Derived columns of sha3_model_bloka.csv follow from the two
#                 raw counts:  cena_po_bloku = (t400 - t50) / 350,
#                 rep_poruke = t50 - 50 * cena_po_bloku.
#
# Usage         : bash sim_sha3_throughput.sh
# Output        : sha3/Results/sim_sha3_throughput/results.csv
# ---------------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/Hardware/src"
SIM="$ROOT/Hardware/sim"
OUT="$ROOT/Results/sim_sha3_throughput"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$OUT"

GHDL_FLAGS="--std=08 -fsynopsys --workdir=$BUILD"

echo "== analyze ($(ghdl --version | head -1)) =="
ghdl -a $GHDL_FLAGS \
    "$SRC/keccak_pkg.vhd" \
    "$SRC/sha3_input_buffer.vhd" \
    "$SRC/keccak_sponge.vhd" \
    "$SRC/sha3_output_buffer.vhd" \
    "$SRC/sha3_top.vhd" \
    "$SRC/sha3_axis_ip.vhd" \
    "$SIM/tb_sha3_throughput.vhd"
ghdl -e $GHDL_FLAGS tb_sha3_throughput

CSV="$OUT/results.csv"
echo "varijanta,rate_b,DATA_WIDTH,ROUNDS_PER_CYCLE,taktova_50_blokova,taktova_400_blokova,cena_po_bloku,rep_poruke,latencija_16B" > "$CSV"

fail=0
for CFG in "32 1" "32 2" "64 1" "64 2"; do
    set -- $CFG
    DW=$1; RPC=$2
    declare -A CYC=()
    for BLOCKS in 50 400; do
        LOG="$BUILD/thr_dw${DW}_rpc${RPC}_b${BLOCKS}.log"
        if ! ghdl -r $GHDL_FLAGS tb_sha3_throughput \
                -gG_ALGORITHM=SHA3 -gG_SHA3_VERSION=256 \
                -gG_DATA_WIDTH=$DW -gG_ROUNDS_PER_CYCLE=$RPC \
                -gG_MSG_BLOCKS=$BLOCKS --stop-time=50ms > "$LOG" 2>&1; then
            echo "FAIL  DW=$DW RPC=$RPC blocks=$BLOCKS"; fail=$((fail+1))
            grep -E "error|TIMEOUT" "$LOG" | head -3
            continue 2
        fi
        CYC[$BLOCKS]=$(grep -o "cycles=[0-9]*" "$LOG" | head -1 | cut -d= -f2)
        LAT=$(grep -o "TLAST = [0-9]* cycles" "$LOG" | grep -o "[0-9]*" | head -1)
    done
    T50=${CYC[50]}; T400=${CYC[400]}
    COST=$(( (T400 - T50) / 350 ))
    TAIL=$(( T50 - 50 * COST ))
    echo "SHA3-256,1088,$DW,$RPC,$T50,$T400,$COST,$TAIL,$LAT" >> "$CSV"
    echo "  DW=$DW RPC=$RPC: t50=$T50 t400=$T400 cost/block=$COST tail=$TAIL latency16B=$LAT"
done

echo "results: $CSV"
[ "$fail" -eq 0 ] && echo "ALL MEASUREMENTS DONE" || echo "SOME MEASUREMENTS FAILED"
