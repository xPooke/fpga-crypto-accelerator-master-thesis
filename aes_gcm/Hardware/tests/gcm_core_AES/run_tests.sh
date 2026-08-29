#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Script Name   : run_tests.sh
# Tool Version  : GHDL (--std=08 -fsynopsys -frelaxed)
#
# Description   : GHDL regression for the GCM core (glue + AES), one level below
#                 the full L3 chain. Everything is analyzed straight out of
#                 ../../ip_cores, so the suite proves the packaged cores and not
#                 a private copy of the sources.
#
#                   AES core : the cipher wrappers on their own
#                   GCM core : gcm_enc_glue / gcm_dec_glue + AES_algorithm, wired
#                              together by the composites in _lib/
#
#                 Usage: ./run_tests.sh [MULTICORE|UNROLLED]   (default: both)
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"          # the testbenches read data/inData.txt relative to the cwd
IP="$(cd "$HERE/../../ip_cores" && pwd)"
# A private GHDL library per run. A fixed work/ next to the script means two
# concurrent runs compile into the same library (and, below, share the same
# golden-vector file), which silently corrupts each other's results.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STD="--std=08 -fsynopsys -frelaxed"
G="ghdl -a $STD --workdir=$WORK"
R="ghdl -r $STD --workdir=$WORK"
E="ghdl -e $STD --workdir=$WORK"


KINDS="${1:-MULTICORE UNROLLED}"

echo "== analyze =="
$G "$IP/AES_ALGORITHM/src/aes_pkg.vhd" 2>/dev/null || exit 1
for f in key_expansion aes_round_column aes_round aes_enc_rolled aes_enc_pipelined \
         AES_multicore_wrapper AES_pipelined_wrapper AES_algorithm; do
  $G "$IP/AES_ALGORITHM/src/$f.vhd" || exit 1
done
for f in GF2_karatsuba_16 GF_karatsuba_32 GF_Karatsuba_64 GF2_Karatsuba_128 \
         GF2_Reduction_128 GF_multiplier GHASH_single GHASH_pipelined GHASH GHASH_wrapper AXIS_skid_buffer \
         axis_broadcaster AXIS_DEMUX AXIS_GHASH_MUX AXIS_MUX Tag_Finalizer gcm_enc_glue; do
  $G "$IP/GCM_GLUE_ENC/src/$f.vhd" || exit 1
done
for f in AXIS_DEMUX_dec AXIS_MUX_DEC Tag_Verifier gcm_dec_glue; do
  $G "$IP/GCM_GLUE_DEC/src/$f.vhd" || exit 1
done
$G "$HERE/_lib/gcm_composites.vhd" || exit 1
for f in "$HERE"/tb/*.vhd; do
  $G "$f" || exit 1
done

TBS="tb_aes_mc tb_aes_pipelined tb_wrap_keyrace tb_key_swallow tb_key_no_iv
     tb_iv_before_key tb_key_idle_race tb_flush_xcheck_mc tb_flush_xcheck_pipe
     tb_gcm_kat tb_gcm_kat_tkeep tb_gcm_enc_src_dense tb_gcm_dec_src_dense
     tb_gcm_loopback_src_dense tb_dec_malformed tb_rekey_on_flush
     tb_reset_midpacket tb_gcm_enc_aes_keyrace tb_gcm_dec_aes_keyrace"
for t in $TBS; do
  $E "$t" || exit 1
done

pass=0; fail=0
verdict () {   # $1 = label, rest = ghdl args
  local label="$1"; shift
  local out
  out=$(timeout 600 $R "$@" --ieee-asserts=disable-at-0 2>&1)
  # The suites do not share one verdict string: some print "RESULT: PASS",
  # others "<tb> PASS: ...". FAIL is checked first so a FAIL line always wins.
  if echo "$out" | grep -qiE "severity failure|RESULT: FAIL|FAIL:|FREEZE|error:"; then
    fail=$((fail+1)); printf "  %-42s FAIL\n" "$label"
    echo "$out" | grep -iE "mismatch|FAIL|FREEZE|error:" | head -3 | sed 's/^/        /'
  elif echo "$out" | grep -qiE "RESULT: PASS|ALL PASS|PASS:"; then
    pass=$((pass+1)); printf "  %-42s PASS\n" "$label"
  else
    fail=$((fail+1)); printf "  %-42s ??  (no verdict)\n" "$label"
  fi
}

echo; echo "== AES core (cipher wrappers, no GCM) =="
verdict "tb_aes_mc            multicore wrapper"  tb_aes_mc
verdict "tb_aes_pipelined     pipelined wrapper"  tb_aes_pipelined
verdict "tb_wrap_keyrace      AES_algorithm"      tb_wrap_keyrace
verdict "tb_key_swallow       key during traffic" tb_key_swallow
verdict "tb_key_no_iv         key without IV"     tb_key_no_iv
verdict "tb_iv_before_key     IV before key"      tb_iv_before_key
verdict "tb_key_idle_race     S_IDLE re-key race" tb_key_idle_race
verdict "tb_flush_xcheck_mc   flush cross-check"  tb_flush_xcheck_mc
verdict "tb_flush_xcheck_pipe flush cross-check"  tb_flush_xcheck_pipe

for KIND in $KINDS; do
  echo; echo "== GCM core, WRAPPER_KIND=$KIND =="
  K="-gG_WRAPPER_KIND=$KIND"

  # --- conformance: the only tests that prove standard compliance
  verdict "tb_gcm_kat        AES128 AAD0"  tb_gcm_kat $K -gG_AES_BITS=128 -gG_AAD_BEATS=0
  verdict "tb_gcm_kat        AES128 AAD2"  tb_gcm_kat $K -gG_AES_BITS=128 -gG_AAD_BEATS=2
  verdict "tb_gcm_kat        AES256 AAD0"  tb_gcm_kat $K -gG_AES_BITS=256 -gG_AAD_BEATS=0
  verdict "tb_gcm_kat        AES128 AAD2 GHASH 1clk" tb_gcm_kat $K -gG_AES_BITS=128 -gG_AAD_BEATS=2 -gG_MULT_CYCLES=1
  verdict "tb_gcm_kat        AES256 AAD0 GHASH 1clk" tb_gcm_kat $K -gG_AES_BITS=256 -gG_AAD_BEATS=0 -gG_MULT_CYCLES=1
  verdict "tb_gcm_kat_tkeep  partial beats" tb_gcm_kat_tkeep $K

  # --- self-consistency: streaming, corner cases
  verdict "tb_gcm_enc_src_dense"            tb_gcm_enc_src_dense $K
  verdict "tb_gcm_dec_src_dense"            tb_gcm_dec_src_dense $K
  verdict "tb_gcm_loopback  AAD0 rekey/5"   tb_gcm_loopback_src_dense $K -gG_AAD_BEATS=0 -gG_REKEY_EVERY=5
  verdict "tb_gcm_loopback  AAD2 rekey/3"   tb_gcm_loopback_src_dense $K -gG_AAD_BEATS=2 -gG_REKEY_EVERY=3
  verdict "tb_dec_malformed  auth reject"   tb_dec_malformed $K
  verdict "tb_rekey_on_flush"               tb_rekey_on_flush $K
  verdict "tb_reset_midpacket"              tb_reset_midpacket $K

  # --- the key-swap freeze reproducer: offsets 1..4 used to deadlock
  echo "  -- key-race freeze sweep (key 0..6 cycles after IV)"
  for OFF in 0 1 2 3 4 5 6; do
    verdict "  enc keyrace off=$OFF" tb_gcm_enc_aes_keyrace -gG_KIND=$KIND -gCOINCIDE=true \
            -gBURST_LEN=1 -gBURST_OFF=$OFF -gWARMUP_PKTS=6 -gNUM_PKTS=40
  done
  verdict "tb_gcm_dec_aes_keyrace"          tb_gcm_dec_aes_keyrace -gG_KIND=$KIND
done

echo
echo "-------------------------------------------"
echo "TOTAL: $((pass+fail))   PASS: $pass   FAIL: $fail"
[ $fail -ne 0 ] && { echo "SOME TESTS FAILED"; exit 1; }
echo "ALL PASS"
