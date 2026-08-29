#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Script Name   : run_tests.sh
# Tool Version  : GHDL (--std=08 -fsynopsys)
#
# Description   : GHDL regression for the full L3 chain. Everything is analyzed
#                 straight out of ../../ip_cores, so the suite proves the packaged
#                 cores and not a private copy of the sources.
#
#                   ENC  chain (5 cores)  : SPLIT_demux + AXIS_full_skid_buffer
#                                           + gcm_enc_glue + AES_algorithm + MERGE_mux
#                   DEC  chain (6 cores)  : + ICV_realign
#                   LOOPBACK (11 cores)   : ENC -> DEC, byte-identical round-trip
#                                           and the tag must verify
#
#                 The two KAT suites prove standard compliance; the ENC and
#                 LOOPBACK sweeps only prove self-consistency, which is a much
#                 weaker claim.
#
#                 Usage: ./run_tests.sh
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP="$(cd "$HERE/../../ip_cores" && pwd)"
L3="$IP/L3_WRAPPER_IP_CORES"
# A private GHDL library per run. A fixed work/ next to the script means two
# concurrent runs compile into the same library (and, below, share the same
# golden-vector file), which silently corrupts each other's results.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
G="ghdl -a --std=08 -fsynopsys --workdir=$WORK"
R="ghdl -r --std=08 -fsynopsys --workdir=$WORK"
E="ghdl -e --std=08 -fsynopsys --workdir=$WORK"


echo "== analyze =="

# --- AES_ALGORITHM
$G "$IP/AES_ALGORITHM/src/aes_pkg.vhd" 2>/dev/null || exit 1
for f in key_expansion aes_round_column aes_round aes_enc_rolled aes_enc_pipelined \
         AES_multicore_wrapper AES_pipelined_wrapper AES_algorithm; do
  $G "$IP/AES_ALGORITHM/src/$f.vhd" || exit 1
done

# --- GCM_GLUE_ENC (also supplies the GHASH / GF / AXIS files the DEC glue shares)
for f in GF2_karatsuba_16 GF_karatsuba_32 GF_Karatsuba_64 GF2_Karatsuba_128 \
         GF2_Reduction_128 GF_multiplier GHASH_single GHASH_pipelined GHASH GHASH_wrapper AXIS_skid_buffer \
         axis_broadcaster AXIS_DEMUX AXIS_GHASH_MUX AXIS_MUX Tag_Finalizer gcm_enc_glue; do
  $G "$IP/GCM_GLUE_ENC/src/$f.vhd" || exit 1
done

# --- GCM_GLUE_DEC (only what is specific to the decrypt side)
for f in AXIS_DEMUX_dec AXIS_MUX_DEC Tag_Verifier gcm_dec_glue; do
  $G "$IP/GCM_GLUE_DEC/src/$f.vhd" || exit 1
done

# --- L3 wrapper cores. util_merge is shared by MERGE_mux and ICV_realign, so it
#     is analyzed once (the two copies are identical).
$G "$L3/SPLIT_demux/src/util_split.vhd"                    || exit 1
$G "$L3/SPLIT_demux/src/SPLIT_demux.vhd"                   || exit 1
$G "$L3/MERGE_mux/src/util_merge.vhd"                      || exit 1
$G "$L3/MERGE_mux/src/MERGE_mux.vhd"                       || exit 1
$G "$L3/ICV_realign/src/ICV_realign.vhd"                   || exit 1
$G "$L3/AXIS_full_skid_buffer/src/AXIS_full_skid_buffer.vhd" || exit 1

# --- test tops + testbenches
for f in top_gcm_enc top_gcm_dec top_gcm_loopback; do
  $G "$HERE/src/$f.vhd" || exit 1
done
for f in tb_gcm_kat tb_gcm_kat_len tb_top_gcm_enc tb_top_gcm_loopback; do
  $G "$HERE/tb/$f.vhd" || exit 1
done
for t in tb_gcm_kat tb_gcm_kat_len tb_top_gcm_enc tb_top_gcm_loopback; do
  $E "$t" || exit 1
done

# ---------------------------------------------------------------------------
# 1. Known-answer test: NIST SP 800-38D / McGrew-Viega test case 4.
#    AAD = 20 B (not a multiple of the bus) and PT = 60 B, so both partial-block
#    paths are exercised against a published vector.
# ---------------------------------------------------------------------------
echo; echo "== KAT (NIST SP 800-38D, test case 4) =="
kat_out=$($R tb_gcm_kat -gKEY_REV=0 -gIV_REV=0 -gVERBOSE=0 --assert-level=none 2>&1)
if echo "$kat_out" | grep -q "RESULT: PASS"; then
  kat_fail=0
  echo "KAT       CT + TAG match the published vector   PASS"
else
  kat_fail=1
  echo "KAT       FAIL"
  echo "$kat_out" | grep -E "mismatch|LENGTH|RESULT" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
# 2. KAT length sweep: every AAD / PT residue mod 16 against a software AES-GCM
#    reference (ref/gen_vectors.py). This is what proves the partial-block path
#    is standard compliant rather than merely self-consistent.
# ---------------------------------------------------------------------------
echo; echo "== KAT length sweep (vs a software AES-GCM reference) =="
if ! python3 -c "import cryptography" 2>/dev/null; then
  echo "SKIPPED - python3 'cryptography' package not installed"
  klen_pass=0; klen_fail=0
else
  klen_pass=0; klen_fail=0
  for A in 1 15 16 17 20 32 33; do
    for P in 1 15 16 17 31 60 63 64 65 100 127 129; do
      python3 "$HERE/ref/gen_vectors.py" $A $P "$WORK/vec.txt" \
        || { klen_fail=$((klen_fail+1)); continue; }
      out=$($R tb_gcm_kat_len -gAAD_BYTES=$A -gPT_BYTES=$P -gVEC_FILE="$WORK/vec.txt" \
            --assert-level=none 2>&1)
      if echo "$out" | grep -q "RESULT: PASS"; then
        klen_pass=$((klen_pass+1))
      else
        klen_fail=$((klen_fail+1))
        printf "FAIL  KAT-LEN  AAD=%s (mod16=%s)  PT=%s (mod16=%s)\n" \
               $A $((A%16)) $P $((P%16))
      fi
    done
  done
  echo "KAT-LEN   TOTAL: $((klen_pass+klen_fail))  PASS: $klen_pass  FAIL: $klen_fail"
fi

# ---------------------------------------------------------------------------
# 3 + 4. Chain sweeps: geometry x back-pressure.
# ---------------------------------------------------------------------------
# "BYPASS AAD PT"
CONFIGS=(
  "50 20 40"    "29 20 40"   "96 32 64"   "50 15 69"   "16 16 128"
  "50 20 16"    "64 16 48"   "33 40 100"  "20 32 55"   "100 48 200"
)
COMBOS=( "100 100" "50 50" "10 90" "90 10" "10 10" )

run_suite () {   # $1 = tb name, $2 = label
  local tb="$1" label="$2" pass=0 fail=0
  for cfg in "${CONFIGS[@]}"; do
    read -r BYP AAD PT <<< "$cfg"
    for cmb in "${COMBOS[@]}"; do
      read -r PV PR <<< "$cmb"
      out=$($R "$tb" -gBYPASS_BYTES=$BYP -gAAD_BYTES=$AAD -gPT_BYTES=$PT \
              -gP_VALID=$PV -gP_READY=$PR -gSEED1=$((BYP+PV+1)) -gSEED2=$((AAD+PR+7)) \
              --assert-level=none 2>&1)
      if echo "$out" | grep -q "RESULT: PASS"; then
        pass=$((pass+1))
      else
        fail=$((fail+1))
        printf "FAIL  %s  BYP=%s AAD=%s PT=%s PV=%s PR=%s\n" "$label" $BYP $AAD $PT $PV $PR
        echo "$out" | grep -E "mismatch|LENGTH|AUTH|TLAST|timeout" | head -3 | sed 's/^/      /'
      fi
    done
  done
  echo "$label  TOTAL: $((pass+fail))  PASS: $pass  FAIL: $fail"
  return $fail
}

echo; echo "== ENC chain (5 cores) =="
run_suite tb_top_gcm_enc      "ENC     "; enc_fail=$?
echo; echo "== LOOPBACK (11 cores, ENC -> DEC round-trip) =="
run_suite tb_top_gcm_loopback "LOOPBACK"; lb_fail=$?

# ---------------------------------------------------------------------------
# 5. Bypass disabled (BYPASS_EN=false): the bypass stream does not exist at all,
#    the whole packet is AAD || PT. Same loopback round-trip + tag verify, which
#    exercises SPLIT_demux, MERGE_mux and both chains with the segment switched
#    off. Existing suites above keep BYPASS_EN at its default (true).
# ---------------------------------------------------------------------------
echo; echo "== BYPASS-OFF (BYPASS_EN=false, no bypass stream) =="
OFF_CONFIGS=( "20 40" "32 64" "16 128" "48 200" "1 15" )
off_pass=0; off_fail=0
for cfg in "${OFF_CONFIGS[@]}"; do
  read -r AAD PT <<< "$cfg"
  for cmb in "${COMBOS[@]}"; do
    read -r PV PR <<< "$cmb"
    out=$($R tb_top_gcm_loopback -gBYPASS_EN=false -gAAD_BYTES=$AAD -gPT_BYTES=$PT \
            -gP_VALID=$PV -gP_READY=$PR -gSEED1=$((AAD+PV+1)) -gSEED2=$((PT+PR+7)) \
            --assert-level=none 2>&1)
    if echo "$out" | grep -q "RESULT: PASS"; then
      off_pass=$((off_pass+1))
    else
      off_fail=$((off_fail+1))
      printf "FAIL  BYPASS-OFF  AAD=%s PT=%s PV=%s PR=%s\n" $AAD $PT $PV $PR
      echo "$out" | grep -E "mismatch|LENGTH|AUTH|TLAST|timeout" | head -3 | sed 's/^/      /'
    fi
  done
done
echo "BYPASS-OFF TOTAL: $((off_pass+off_fail))  PASS: $off_pass  FAIL: $off_fail"

echo
echo "-------------------------------------------"
if [ $((enc_fail + lb_fail + kat_fail + klen_fail + off_fail)) -ne 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
echo "ALL PASS"
