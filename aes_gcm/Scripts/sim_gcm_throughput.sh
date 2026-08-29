#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Script Name   : sim_gcm_throughput.sh
# Tool Version  : GHDL (--std=08 -fsynopsys -frelaxed)
#
# Description   : Cycle-accurate throughput sweep for the AES-GCM encryptor,
#                 the counterpart of the SHA-3 throughput measurement.  Drives
#                 tb_gcm_throughput through four series, each answering one
#                 question the thesis leaves open:
#
#                   A  steady state   -> bits/clock ceiling per architecture
#                   B  backpressure   -> GLOBAL vs PER_STAGE, which synthesis
#                                        cannot decide
#                   C  short packets  -> what pipeline fill and per-packet H,
#                                        E_K(J0) really cost at network sizes
#                   D  GHASH ceiling  -> does MULT_CYCLES 1 vs 2 really halve
#                                        the ceiling, as tab:ghash_plafon says
#
# Usage         : ./Scripts/sim_gcm_throughput.sh [A|B|C|D|all]   (default: all)
#                 RESUME=0 ./Scripts/sim_gcm_throughput.sh all    (measure anew)
# Output        : Results/sim_gcm_throughput/results.csv
#
# Notes
#   * DATA_WIDTH is fixed at 128.  The AES block is 128 bits, so unlike SHA-3
#     the bus width is not a design variable here.
#   * bits/clock counts PAYLOAD only; the ICV beat costs time but is not
#     payload, which is what it also is on a real link.
#   * Every run carries a structural check (output beat count).  A run that
#     fails it is written to the CSV with status FAIL and must not be used.
#   * RESUME (default 1) works as in the Vivado sweep scripts.  A full run
#     keeps the rows already in results.csv and skips those configurations;
#     naming one series remeasures that series and leaves every other row
#     alone, which is what -tclargs <name> does there.  RESUME=0 on a full run
#     wipes the file, and a header that does not match starts from scratch.
#     Rows with status FAIL are always remeasured: a FAIL is a crash or the
#     1800 s timeout, so it is a property of the run and not of the design.
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IP="$ROOT/Hardware/ip_cores"
TB="$ROOT/Hardware/tests/gcm_core_AES"
OUT="$ROOT/Results/sim_gcm_throughput"
SERIES="${1:-all}"
RESUME="${RESUME:-1}"

case "$SERIES" in
  A|B|C|D|all) ;;
  *) echo "unknown series: $SERIES  (allowed: A B C D all)" >&2 ; exit 2 ;;
esac

STD="--std=08 -fsynopsys -frelaxed"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
G="ghdl -a $STD --workdir=$WORK"
E="ghdl -e $STD --workdir=$WORK"
R="ghdl -r $STD --workdir=$WORK"

mkdir -p "$OUT"
CSV="$OUT/results.csv"

# ---------------------------------------------------------------------------
# Analyze.  Same order as the regression suite, straight out of ip_cores, so
# what is measured is the packaged core and not a private copy.
# ---------------------------------------------------------------------------
echo "== analyze =="
$G "$IP/AES_ALGORITHM/src/aes_pkg.vhd" 2>/dev/null || exit 1
for f in key_expansion aes_round_column aes_round aes_enc_rolled aes_enc_pipelined \
         AES_multicore_wrapper AES_pipelined_wrapper AES_algorithm; do
  $G "$IP/AES_ALGORITHM/src/$f.vhd" || exit 1
done
for f in GF2_karatsuba_16 GF_karatsuba_32 GF_Karatsuba_64 GF2_Karatsuba_128 \
         GF2_Reduction_128 GF_multiplier GHASH_single GHASH_pipelined GHASH \
         GHASH_wrapper AXIS_skid_buffer axis_broadcaster AXIS_DEMUX \
         AXIS_GHASH_MUX AXIS_MUX Tag_Finalizer gcm_enc_glue; do
  $G "$IP/GCM_GLUE_ENC/src/$f.vhd" || exit 1
done
for f in AXIS_DEMUX_dec AXIS_MUX_DEC Tag_Verifier gcm_dec_glue; do
  $G "$IP/GCM_GLUE_DEC/src/$f.vhd" || exit 1
done
$G "$TB/_lib/gcm_composites.vhd"        || exit 1
$G "$TB/tb/tb_gcm_throughput.vhd"       || exit 1
$E tb_gcm_throughput                    || exit 1

# ---------------------------------------------------------------------------
# Resume.  A row is identified by its parameters, fields 1-12; there is no
# configuration name here as there is in the Vivado sweeps.  Rows that survive
# are written back under the header, and new ones are appended as they are
# measured, so an interrupted run keeps everything it had already produced.
# ---------------------------------------------------------------------------
CSV_HDR="serija,kind,round,flow,cores,mult,pkt_beats,n_pkts,in_pct,out_pct,burst_go,burst_stall,cycles,out_beats,exp_beats,bita_po_taktu,status"

declare -A have
KEPT=()

# Does a row's serija field belong to the series asked for?  B covers B2 and B3,
# which are sub-blocks of the backpressure series and not arguments of their own.
in_series () {
  case "$SERIES" in
    B) [ "$1" = B ] || [ "$1" = B2 ] || [ "$1" = B3 ] ;;
    *) [ "$1" = "$SERIES" ] ;;
  esac
}

if [ -f "$CSV" ] && [ "$(head -1 "$CSV")" != "$CSV_HDR" ]; then
  echo "-- results.csv was written with an older header, starting over"
elif [ -f "$CSV" ] && { [ "$SERIES" != all ] || [ "$RESUME" = 1 ]; }; then
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    ser=${row%%,*}
    st=${row##*,}
    # Remeasured, so not kept: the series that was asked for, and every FAIL.
    if [ "$SERIES" != all ] && in_series "$ser"; then continue; fi
    [ "$st" = FAIL ] && continue
    KEPT+=("$row")
    have["$(echo "$row" | cut -d, -f1-12)"]=1
  done < <(tail -n +2 "$CSV")
fi

{ echo "$CSV_HDR"
  [ ${#KEPT[@]} -gt 0 ] && printf '%s\n' "${KEPT[@]}"
} > "$CSV"
[ ${#KEPT[@]} -gt 0 ] && echo "-- rows kept from results.csv: ${#KEPT[@]}"

# run <serija> <kind> <round> <flow> <cores> <mult> <pkt> <n> <in%> <out%> [go] [stall]
run () {
  local ser=$1 kind=$2 round=$3 flow=$4 cores=$5 mult=$6 pkt=$7 n=$8 inp=$9 outp=${10}
  local go=${11:-0} stall=${12:-0}
  printf "  %-2s %-9s %-4s %-9s c=%-2s m=%s pkt=%-4s n=%-2s in=%-3s out=%-3s b=%s/%-3s " \
         "$ser" "$kind" "$round" "$flow" "$cores" "$mult" "$pkt" "$n" "$inp" "$outp" "$go" "$stall"
  local key="$ser,$kind,$round,$flow,$cores,$mult,$pkt,$n,$inp,$outp,$go,$stall"
  if [ -n "${have[$key]+x}" ]; then
    echo "already in results.csv, skipping"
    return
  fi
  local o
  o=$(timeout 1800 $R tb_gcm_throughput \
        -gG_WRAPPER_KIND="$kind" -gG_ROUND_STYLE="$round" -gG_FLOW_STYLE="$flow" \
        -gG_NUM_CORES="$cores"   -gG_MULT_CYCLES="$mult" \
        -gG_PKT_BEATS="$pkt"     -gG_NUM_PACKETS="$n" \
        -gG_IN_VALID_PCT="$inp"  -gG_OUT_READY_PCT="$outp" \
        -gG_BURST_GO="$go"       -gG_BURST_STALL="$stall" \
        --ieee-asserts=disable-at-0 2>&1)
  local line
  line=$(echo "$o" | grep '^CSV,' | head -1)
  if [ -z "$line" ]; then
    echo "NO RESULT"
    echo "$ser,$kind,$round,$flow,$cores,$mult,$pkt,$n,$inp,$outp,$go,$stall,,,,,FAIL" >> "$CSV"
    return
  fi
  # CSV,kind,round,flow,cores,mult,pkt,n,in,out,cycles,out_beats,exp_beats
  local cyc ob eb bpc st
  cyc=$(echo "$line" | cut -d, -f11)
  ob=$(echo  "$line" | cut -d, -f12)
  eb=$(echo  "$line" | cut -d, -f13)
  bpc=$(awk -v n="$n" -v p="$pkt" -v c="$cyc" 'BEGIN{ if(c>0) printf "%.2f", n*p*128/c; else print "0" }')
  if [ "$ob" = "$eb" ]; then st=OK; else st=FAIL; fi
  printf "%8s cycles  %7s bits/clk  %s\n" "$cyc" "$bpc" "$st"
  echo "$ser,$kind,$round,$flow,$cores,$mult,$pkt,$n,$inp,$outp,$go,$stall,$cyc,$ob,$eb,$bpc,$st" >> "$CSV"
}

# ---------------------------------------------------------------------------
# A  Steady state.  One long packet, no throttling: the ceiling each
#    architecture can reach once the pipeline is full.
# ---------------------------------------------------------------------------
if [ "$SERIES" = A ] || [ "$SERIES" = all ]; then
  echo "== A: steady state =="
  # c = 15, not 14, is the one-block-per-clock point: a rolled core holds a
  # block N_r + 1 = 15 clocks (N_r rounds plus one clock in S_DONE until the
  # wrapper takes the result), so c cores retire c/15 blocks per clock.
  run A UNROLLED  BRAM GLOBAL 0  1 512 1 100 100
  for c in 1 2 4 7 8 14 15; do
    run A MULTICORE BRAM GLOBAL $c 1 512 1 100 100
  done
fi

# ---------------------------------------------------------------------------
# B  Backpressure.  Same work, sink throttled.  This is the only measurement
#    that can decide GLOBAL vs PER_STAGE: synthesis already showed PER_STAGE
#    is worse in area and fmax, so if it does not win here either, it has no
#    case at all.
# ---------------------------------------------------------------------------
if [ "$SERIES" = B ] || [ "$SERIES" = all ]; then
  echo "== B: back-pressure =="
  for flow in GLOBAL PER_STAGE; do
    for outp in 100 90 75 50 25; do
      run B UNROLLED BRAM $flow 0 1 512 1 100 "$outp"
    done
  done
  echo "-- B2: stall on the input too --"
  for flow in GLOBAL PER_STAGE; do
    run B2 UNROLLED BRAM $flow 0 1 512 1 75 75
  done
  # B3: bursty sink.  Per-clock random throttling never forms a burst, so the
  # sink becomes the bottleneck and the flow-control style stays invisible.
  # Here the sink accepts GO clocks, then stalls STALL clocks; PER_STAGE has
  # N_r+2 = 16 free slots to absorb the stall, while GLOBAL freezes the whole
  # stream.
  echo "-- B3: bursty sink (GO/STALL) --"
  for flow in GLOBAL PER_STAGE; do
    for b in "8 8" "16 16" "32 32" "8 24" "64 16"; do
      set -- $b
      run B3 UNROLLED BRAM $flow 0 1 512 1 100 0 $1 $2
    done
  done
fi

# ---------------------------------------------------------------------------
# C  Short packets at network sizes.  16 B per beat, so 4 / 32 / 94 beats are
#    64 B / 512 B / 1500 B.  Packet count is chosen to keep the payload
#    roughly constant across rows, so the columns stay comparable.
# ---------------------------------------------------------------------------
if [ "$SERIES" = C ] || [ "$SERIES" = all ]; then
  echo "== C: short packets =="
  run C UNROLLED BRAM GLOBAL 0 1   4 64 100 100   # 64 B
  run C UNROLLED BRAM GLOBAL 0 1  32 16 100 100   # 512 B
  run C UNROLLED BRAM GLOBAL 0 1  94  8 100 100   # 1500 B
  run C UNROLLED BRAM GLOBAL 0 1 512  1 100 100   # reference, long message
fi

# ---------------------------------------------------------------------------
# D  GHASH ceiling.  Enough AES capacity that the cipher is not the limit, so
#    what is left is the authentication path.
# ---------------------------------------------------------------------------
if [ "$SERIES" = D ] || [ "$SERIES" = all ]; then
  echo "== D: GHASH ceiling =="
  # Multicore points are chosen around the ceilings: c/15 blocks per clock, so
  # c = 15 covers the single-cycle GHASH (1.0) and c = 8 the two-cycle one
  # (8/15 = 0.53 > 0.5).
  for m in 1 2; do
    run D UNROLLED  BRAM GLOBAL 0  "$m" 512 1 100 100
    run D MULTICORE BRAM GLOBAL 15 "$m" 512 1 100 100
    run D MULTICORE BRAM GLOBAL 8  "$m" 512 1 100 100
  done
fi

echo
echo "results: $CSV"
awk -F, 'NR>1 && $17=="FAIL" {n++} END{ if(n) print "  WARNING: " n " configurations with structural errors"; else print "  all configurations structurally valid" }' "$CSV"
