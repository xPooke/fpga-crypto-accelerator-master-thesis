#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GHDL regression runner for the packaged ICV_realign IP.
# Analyzes the IP's own sources (../src).
# Sweeps generic configs x (P_VALID, P_READY) probability combos.
# Usage: ./run_icv_realign_tests.sh
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
ghdl -a $GHDL_FLAGS "$SRC/util_merge.vhd"   || exit 1
ghdl -a $GHDL_FLAGS "$SRC/ICV_realign.vhd"  || exit 1
ghdl -a $GHDL_FLAGS "$HERE/tb_ICV_realign.vhd" || exit 1
ghdl -e $GHDL_FLAGS tb_ICV_realign               || exit 1

# generic configs: "DATA_WIDTH AAD_BEATS CT_BYTES"
CONFIGS=(
  # --- DATA_WIDTH = 128 (16-byte bus, ICV = 16 B) ---
  "128 2 40"     # base: CT tail 8, tag straddles two beats
  "128 2 69"     # CT tail 5
  "128 2 1"      # single CT byte
  "128 2 15"     # CT one byte short of a beat
  "128 2 16"     # CT exactly one beat -> ICV lands on its own input beat
  "128 2 32"     # CT aligned, 2 beats
  "128 2 0"      # DEGENERATE: no CT at all, segment is just the tag
  "128 0 40"     # no AAD passthrough (starts in S_PRIME)
  "128 0 0"      # no AAD and no CT: one beat in, one beat out
  "128 1 40"     # single AAD beat
  "128 4 100"    # more AAD beats
  "128 2 200"    # long CT
  "128 3 511"    # long CT, tail 15
  # --- DATA_WIDTH = 64 (8-byte bus, ICV = 8 B) ---
  "64 2 40"
  "64 2 0"
  "64 2 7"
  "64 0 33"
  "64 3 64"      # CT aligned
  # --- DATA_WIDTH = 256 (32-byte bus, ICV = 32 B) ---
  "256 2 100"
  "256 2 0"
  "256 1 32"     # CT aligned to one beat
  "256 4 300"
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
)

pass=0; fail=0; failed_list=""
for cfg in "${CONFIGS[@]}"; do
  read -r DW AB CT <<< "$cfg"
  for cmb in "${COMBOS[@]}"; do
    read -r PV PR <<< "$cmb"
    tag="DW=$DW AAD_BEATS=$AB CT=$CT PV=$PV PR=$PR"
    out=$(ghdl -r $GHDL_FLAGS tb_ICV_realign \
            -gDATA_WIDTH=$DW -gAAD_BEATS=$AB -gCT_BYTES=$CT \
            -gP_VALID=$PV -gP_READY=$PR -gSEED1=$((CT+PV+1)) -gSEED2=$((AB+PR+7)) \
            --assert-level=none 2>&1)
    if echo "$out" | grep -q "RESULT: PASS"; then
      pass=$((pass+1)); printf "PASS  %s\n" "$tag"
    else
      fail=$((fail+1)); failed_list+="  $tag\n"
      printf "FAIL  %s\n" "$tag"
      echo "$out" | grep -E "mismatch|TLAST|TIMEOUT|count|full|RESULT" | head -4 | sed 's/^/      /'
    fi
  done
done

echo "-------------------------------------------"
echo "TOTAL: $((pass+fail))   PASS: $pass   FAIL: $fail"
if [ "$fail" -ne 0 ]; then echo -e "Failed:\n$failed_list"; exit 1; fi
echo "ALL PASS"
