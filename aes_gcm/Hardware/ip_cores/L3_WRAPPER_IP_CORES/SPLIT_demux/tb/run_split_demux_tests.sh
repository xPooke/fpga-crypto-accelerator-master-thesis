#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GHDL regression runner for the packaged SPLIT_demux IP.
# Analyzes the IP's own sources (../src) and sweeps generic configs x
# (P_VALID, P_READY) probability combos.
#
# Usage: ./run_split_demux_tests.sh
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../src" && pwd)"
# A private GHDL library per run: a fixed work dir next to the script means two
# concurrent runs compile into the same library and corrupt each other's results.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
GHDL_FLAGS="--std=08 -fsynopsys --workdir=$WORK"

rm -f "$WORK"/*.cf 2>/dev/null

echo "== analyze =="
ghdl -a $GHDL_FLAGS "$SRC/util_split.vhd"     || exit 1
ghdl -a $GHDL_FLAGS "$SRC/SPLIT_demux.vhd"    || exit 1
ghdl -a $GHDL_FLAGS "$HERE/tb_SPLIT_demux.vhd" || exit 1
ghdl -e $GHDL_FLAGS tb_SPLIT_demux             || exit 1

# generic configs: "DATA_WIDTH BYPASS AAD PT"
CONFIGS=(
  # --- DATA_WIDTH = 128 (16-byte bus) ---
  "128 50 20 40"    # bypass gap 14, AAD DRAIN last, PT flush
  "128 50 20 12"    # PT short last beat, no flush
  "128 29 20 40"    # bypass gap 3, AAD COMBINE last, PT flush
  "128 29 20 16"    # 29/20 no-flush corner (last input beat 1 valid byte)
  "128 96 32 40"    # ALIGNED/ALIGNED (gap_byp=0, gap_aad=0) - null-range slices
  "128 96 32 32"    # aligned/aligned, aligned PT
  "128 96 20 40"    # aligned bypass (gap=0), partial AAD, COMBINE last
  "128 50 32 40"    # partial bypass, aligned AAD (rem=16), COMBINE last
  "128 64 16 40"    # aligned/aligned, single AAD beat
  "128 50 10 40"    # single AAD beat, DRAIN
  "128 50 4 40"     # tiny AAD (< bypass gap), DRAIN
  "128 50 40 50"    # 3 AAD beats, DRAIN last
  "128 50 48 50"    # 3 AAD beats, aligned AAD, COMBINE last
  "128 100 40 41"   # larger, partial/partial
  "128 33 40 40"    # bypass gap 15, 3 AAD beats
  # --- PT short enough to sit entirely in the AAD-tail beat (PT <= gap_after_aad) ---
  "128 50 20 8"     # gap_after_aad 10, PT 8
  "128 50 20 10"    # gap_after_aad 10, PT 10 (exactly at the boundary)
  "128 29 20 10"    # gap_after_aad 15, PT 10
  "128 29 20 15"    # gap_after_aad 15, PT 15 (boundary)
  "128 16 20 5"     # aligned bypass, gap_after_aad 12, PT 5
  "128 50 15 1"     # gap_after_aad 15, PT 1 (single PT byte)
  "64 24 12 3"      # 8-byte bus, gap_after_aad 4, PT 3
  # --- large AAD / PT ---
  "128 50 96 200"   # AAD 6 beats, large PT
  "128 16 64 512"   # aligned bypass 1 beat, AAD 4 beats, big PT
  "128 200 128 300" # everything large
  # --- DATA_WIDTH = 64 (8-byte bus) ---
  "64 50 20 40"
  "64 40 16 33"
  "64 24 12 40"
  "64 32 8 40"      # aligned/aligned on 8-byte bus
  "64 17 9 25"
  # --- DATA_WIDTH = 256 (32-byte bus) ---
  "256 100 48 200"
  "256 96 64 100"   # aligned/aligned on 32-byte bus
)

# (P_VALID P_READY) combos from {10,30,50,70,90,100}
COMBOS=(
  "100 100"
  "50 50"
  "10 90"
  "90 10"
  "30 70"
  "70 30"
  "10 10"
)

pass=0; fail=0; failed_list=""
for cfg in "${CONFIGS[@]}"; do
  read -r DW BYP AAD PT <<< "$cfg"
  for cmb in "${COMBOS[@]}"; do
    read -r PV PR <<< "$cmb"
    tag="DW=$DW BYP=$BYP AAD=$AAD PT=$PT PV=$PV PR=$PR"
    out=$(ghdl -r $GHDL_FLAGS tb_SPLIT_demux \
            -gDATA_WIDTH=$DW -gBYPASS_BYTES=$BYP -gAAD_BYTES=$AAD -gPT_BYTES=$PT \
            -gP_VALID=$PV -gP_READY=$PR -gSEED1=$((BYP+PV+1)) -gSEED2=$((AAD+PR+7)) \
            --assert-level=none 2>&1)
    if echo "$out" | grep -q "RESULT: PASS"; then
      pass=$((pass+1)); printf "PASS  %s\n" "$tag"
    else
      fail=$((fail+1)); failed_list+="  $tag\n"
      printf "FAIL  %s\n" "$tag"
      echo "$out" | grep -E "mismatch|TLAST|timeout|RESULT" | sed 's/^/      /'
    fi
  done
done

echo "-------------------------------------------"
echo "TOTAL: $((pass+fail))   PASS: $pass   FAIL: $fail"
if [ "$fail" -ne 0 ]; then echo -e "Failed:\n$failed_list"; exit 1; fi
echo "ALL PASS"
