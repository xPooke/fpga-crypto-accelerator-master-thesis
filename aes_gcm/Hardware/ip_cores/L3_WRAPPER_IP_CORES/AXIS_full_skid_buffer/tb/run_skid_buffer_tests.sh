#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GHDL regression runner for the packaged AXIS_full_skid_buffer IP.
# Analyzes the IP's own sources (../src).
# Sweeps generic configs x (P_VALID, P_READY) probability combos.
# Usage: ./run_skid_buffer_tests.sh
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
ghdl -a $GHDL_FLAGS "$SRC/AXIS_full_skid_buffer.vhd"    || exit 1
ghdl -a $GHDL_FLAGS "$HERE/tb_AXIS_full_skid_buffer.vhd"  || exit 1
ghdl -e $GHDL_FLAGS tb_AXIS_full_skid_buffer                 || exit 1

# generic configs: "DATA_WIDTH BEATS"
CONFIGS=(
  "128 1"      # single beat
  "128 2"      # two beats: the skid can only fill from the second one on
  "128 17"     # partial + TLAST beats land off the pattern boundary
  "128 64"
  "128 256"
  "64 64"
  "256 64"
  "32 33"
)

# (P_VALID P_READY) combos over {10,30,50,70,90,100}
COMBOS=(
  "100 100"    # full rate: the no-bubble check is armed here
  "100 50"     # downstream throttles -> the skid is exercised
  "50 100"     # upstream throttles
  "90 90"
  "70 70"
  "50 50"
  "30 30"
  "10 10"
  "10 90"
  "90 10"
  "30 70"
  "70 30"
)

pass=0; fail=0; failed_list=""
for cfg in "${CONFIGS[@]}"; do
  read -r DW BEATS <<< "$cfg"
  for cmb in "${COMBOS[@]}"; do
    read -r PV PR <<< "$cmb"
    tag="DW=$DW BEATS=$BEATS PV=$PV PR=$PR"
    out=$(ghdl -r $GHDL_FLAGS tb_AXIS_full_skid_buffer \
            -gDATA_WIDTH=$DW -gBEATS=$BEATS \
            -gP_VALID=$PV -gP_READY=$PR -gSEED1=$((BEATS+PV+1)) -gSEED2=$((DW+PR+7)) \
            --assert-level=none 2>&1)
    if echo "$out" | grep -q "RESULT: PASS"; then
      pass=$((pass+1)); printf "PASS  %s\n" "$tag"
    else
      fail=$((fail+1)); failed_list+="  $tag\n"
      printf "FAIL  %s\n" "$tag"
      echo "$out" | grep -E "mismatch|TIMEOUT|bubble|beats|RESULT" | head -4 | sed 's/^/      /'
    fi
  done
done

echo "-------------------------------------------"
echo "TOTAL: $((pass+fail))   PASS: $pass   FAIL: $fail"
if [ "$fail" -ne 0 ]; then echo -e "Failed:\n$failed_list"; exit 1; fi
echo "ALL PASS"
