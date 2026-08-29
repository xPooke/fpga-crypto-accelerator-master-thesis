#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GHDL regression runner for the packaged MERGE_mux IP.
# Analyzes the IP's own sources (../src) and sweeps generic configs x
# (P_VALID, P_READY) probability combos.
#
# Usage: ./run_merge_mux_tests.sh
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
ghdl -a $GHDL_FLAGS "$SRC/util_merge.vhd"    || exit 1
ghdl -a $GHDL_FLAGS "$SRC/MERGE_mux.vhd"     || exit 1
ghdl -a $GHDL_FLAGS "$HERE/tb_MERGE_mux.vhd" || exit 1
ghdl -e $GHDL_FLAGS tb_MERGE_mux             || exit 1

# generic configs: "DATA_WIDTH BYPASS AAD CT ICV"
CONFIGS=(
  # --- DATA_WIDTH = 128 (16-byte bus) ---
  "128 50 20 40 16"    # base: partial bypass, partial AAD, partial CT, flush
  "128 50 15 69 16"    # doc example
  "128 50 20 12 16"    # short CT
  "128 29 20 40 16"    # odd bypass gap 3
  "128 33 40 40 16"    # bypass gap 15
  "128 96 32 64 16"    # aligned bypass, aligned AAD
  "128 64 16 40 16"    # aligned bypass, single AAD beat
  "128 48 16 32 16"    # total = 112 = 7*16 -> NO flush (exact)
  "128 16 1 1 16"      # tiny AAD/CT (1 byte each)
  "128 50 0 40 16"     # AAD = 0  (crypto = CT || ICV)
  "128 50 40 0 16"     # CT  = 0  (crypto = AAD || ICV)
  "128 100 40 200 16"  # large CT
  "128 50 96 200 16"   # large AAD and CT
  "128 200 128 300 16" # everything large
  # --- DATA_WIDTH = 64 (8-byte bus) ---
  "64 50 20 40 16"
  "64 40 16 33 16"
  "64 24 12 40 16"
  "64 17 9 25 16"
  "64 32 8 40 8"       # aligned, ICV = 8 (single beat)
  # --- DATA_WIDTH = 256 (32-byte bus) ---
  "256 100 48 200 16"  # ICV = 16 -> partial ICV beat (16 < 32)
  "256 96 64 100 32"   # aligned bypass/AAD, ICV = 32 (full)
  "256 200 128 300 16"
)

# (P_VALID P_READY) combos over {10,30,50,70,90,100}
COMBOS=(
  "100 100"
  "90 90"
  "70 70"
  "50 50"
  "30 30"
  "10 10"
  "10 90"
  "90 10"
  "30 70"
  "70 30"
  "10 30"
  "30 10"
)

pass=0; fail=0; failed_list=""
for cfg in "${CONFIGS[@]}"; do
  read -r DW BYP AAD CT ICV <<< "$cfg"
  for cmb in "${COMBOS[@]}"; do
    read -r PV PR <<< "$cmb"
    tag="DW=$DW BYP=$BYP AAD=$AAD CT=$CT ICV=$ICV PV=$PV PR=$PR"
    out=$(ghdl -r $GHDL_FLAGS tb_MERGE_mux \
            -gDATA_WIDTH=$DW -gBYPASS_BYTES=$BYP -gAAD_BYTES=$AAD -gCT_BYTES=$CT -gICV_BYTES=$ICV \
            -gP_VALID=$PV -gP_READY=$PR -gSEED1=$((BYP+CT+PV+1)) -gSEED2=$((AAD+ICV+PR+7)) \
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
