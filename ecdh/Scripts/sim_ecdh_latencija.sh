#!/usr/bin/env bash
#-----------------------------------------------------------------------------------
# Company       : University of Belgrade, School of Electrical Engineering (ETF)
# Engineer      : Marko Gavrilović
# Email         : markog0403@gmail.com
#
# Create Date   : August 2026
# Design Name   : sim_ecdh_latencija
# Tool Version  : Vivado Simulator 2025.1 (xvhdl / xelab / xsim)
#
# Description   : Measures the number of clock cycles one scalar multiplication (kP)
#                 takes on each ECDH core, over a representative set of digit widths.
#                 Synthesis measured the cost of the two cores; this measures the
#                 gain, which is what the thesis needs before it may say which core
#                 wins. Runs tb_ecdh_latencija, which instantiates the bare core, so
#                 no AXI-Stream wrapper overhead is folded into the figure.
#
# Usage         : ./sim_ecdh_latencija.sh            # every configuration
#                 ./sim_ecdh_latencija.sh f1_d32     # one configuration again
#                 RESUME=0 ./sim_ecdh_latencija.sh   # discard results.csv, start over
#
# Output        : ecdh/Results/sim_ecdh_latencija/results.csv
#                 config,faza,G_D,q,bitlen_k,taktova_kP,Fmax_MHz,us_po_kP,status
#
# Notes         : RESUME keeps rows already in results.csv and skips those
#                 configurations, exactly like the Vivado sweep scripts. A row
#                 whose status is FAIL is always measured again, because FAIL means
#                 the run crashed or timed out rather than that the design is wrong.
#                 Everything runs in a temporary directory outside the repository:
#                 xsim drops xsim.dir/, *.pb, *.wdb and its logs into the current
#                 directory.
#
# Revision      :
#   0.01 - August 2026 - File Created
#-----------------------------------------------------------------------------------
set -u

#-----------------------------------------------------------------------------------
# Vivado. settings64.sh points at a doubled, non-existent path in this install, so
# the environment is set directly.
#-----------------------------------------------------------------------------------
export XILINX_VIVADO="${XILINX_VIVADO:-/tools/Xilinx/2025.1/Vivado}"
export PATH="$XILINX_VIVADO/bin:$PATH"

for tool in xvhdl xelab xsim; do
    command -v "$tool" >/dev/null 2>&1 || { echo "!! $tool not in PATH ($XILINX_VIVADO/bin)"; exit 1; }
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IP="$ROOT/Hardware/ip_cores_ECDH/ECDH"
SRC="$IP/src"
SIM="$IP/sim"
OUT="$ROOT/Results/sim_ecdh_latencija"
CSV="$OUT/results.csv"

RESUME="${RESUME:-1}"
ONLY="${1:-}"
TIMEOUT_S="${TIMEOUT_S:-7200}"
G_M=571
VEC="$SIM/ladder_vec_b571.txt"

CSV_HDR="config,faza,G_D,q,bitlen_k,taktova_kP,Fmax_MHz,us_po_kP,status"

# faza:G_D  -- phase 1 is the basic core, phase 2 the low latency core
CONFIGS=(
    "1:1"  "1:2"  "1:4"  "1:8"  "1:16"  "1:32"  "1:64"  "1:128"
    "2:1"  "2:2"  "2:4"  "2:8"  "2:16"  "2:32"  "2:64"  "2:128"
)

# Post-implementation Fmax from results/ecdh_synth.csv, used only to turn
# the cycle count into microseconds in the same row. Measurement itself does not
# depend on it. f2_d128 is 0.0 because that configuration does not fit on the
# K26, so it has a cycle count but no time.
fmax_of () {
    case "$1" in
        1:1)   echo 323.17 ;;  1:2)   echo 320.79 ;;  1:4)   echo 280.26 ;;  1:8)   echo 277.84 ;;
        1:16)  echo 247.05 ;;  1:32)  echo 215.29 ;;  1:64)  echo 184.93 ;;  1:128) echo 139.38 ;;
        2:1)   echo 315.62 ;;  2:2)   echo 302.18 ;;  2:4)   echo 265.52 ;;  2:8)   echo 260.68 ;;
        2:16)  echo 230.74 ;;  2:32)  echo 182.15 ;;  2:64)  echo 126.35 ;;  2:128) echo 0.0    ;;
        *)     echo 0.0 ;;
    esac
}

mkdir -p "$OUT"
[ -f "$VEC" ] || { echo "!! vector file missing: $VEC"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$VEC" "$WORK/ladder_vec.txt"

#-----------------------------------------------------------------------------------
# RESUME: keep rows already measured, unless the header changed or RESUME=0.
#-----------------------------------------------------------------------------------
declare -A HAVE
KEPT=()
if [ -f "$CSV" ]; then
    if [ "$(head -1 "$CSV")" = "$CSV_HDR" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            name="${line%%,*}"
            status="${line##*,}"
            [ "$name" = "$ONLY" ] && continue
            [ "$status" = "FAIL" ] && continue      # a failed run is re-measured
            KEPT+=("$line")
            HAVE["$name"]=1
        done < <(tail -n +2 "$CSV")
    else
        echo "-- results.csv was written with an older header, starting over"
    fi
fi
if [ -z "$ONLY" ] && [ "$RESUME" != "1" ]; then
    KEPT=()
    HAVE=()
fi

{
    echo "$CSV_HDR"
    for line in ${KEPT+"${KEPT[@]}"}; do echo "$line"; done
} > "$CSV"
[ ${#KEPT[@]} -gt 0 ] && echo "-- kept ${#KEPT[@]} existing rows kept in results.csv"

#-----------------------------------------------------------------------------------
# Analyse once. Source order follows scripts/package_ecdh_ip.tcl, which is the
# topologically correct list; the packaged core is analysed, not a private copy.
#-----------------------------------------------------------------------------------
echo "-- analyzing sources ($(xvhdl --version 2>&1 | head -1))"
( cd "$WORK" && xvhdl -2008 -work work \
    "$SRC/gf_alu_pkg.vhd" \
    "$SRC/gf_add.vhd" "$SRC/gf_sqr.vhd" "$SRC/gf_mul.vhd" "$SRC/gf_inv.vhd" \
    "$SRC/gf_alu.vhd" "$SRC/ec_cswap.vhd" \
    "$SRC/ec_step_mxy.vhd" "$SRC/ecdh_core_basic.vhd" \
    "$SRC/ec_point_step_par.vhd" "$SRC/ec_scalar_mult_par.vhd" \
    "$SRC/ec_mxy_batch.vhd" "$SRC/ecdh_core_low_latency.vhd" \
    "$SIM/tb_ecdh_latencija.vhd" ) > "$WORK/xvhdl.out" 2>&1
if [ $? -ne 0 ]; then
    echo "!! analysis failed:"; tail -30 "$WORK/xvhdl.out"; exit 1
fi

#-----------------------------------------------------------------------------------
# Measure.
#-----------------------------------------------------------------------------------
n_ok=0
n_fail=0
for cfg in "${CONFIGS[@]}"; do
    faza="${cfg%%:*}"
    d="${cfg##*:}"
    name="f${faza}_d${d}"

    [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
    if [ -z "$ONLY" ] && [ -n "${HAVE[$name]:-}" ]; then
        echo "-- $name is already in results.csv, skipping"
        continue
    fi

    if [ "$faza" = "2" ]; then ll="true"; else ll="false"; fi
    snap="sim_$name"

    echo "-- $name  (faza $faza, G_D=$d, q=$(( (G_M + d - 1) / d )))  $(date +%H:%M:%S)"

    ( cd "$WORK" && xelab -O3 --nolog work.tb_ecdh_latencija -s "$snap" \
        -generic_top "G_M=$G_M" \
        -generic_top "G_D=$d" \
        -generic_top "G_LOW_LATENCY=$ll" \
        -generic_top "G_MAX_VEC=1" ) > "$WORK/xelab_$name.out" 2>&1
    if [ $? -ne 0 ]; then
        echo "   !! elaboration failed"; tail -20 "$WORK/xelab_$name.out"
        n_fail=$((n_fail + 1))
        continue
    fi

    t0=$(date +%s)
    ( cd "$WORK" && timeout "$TIMEOUT_S" xsim "$snap" --nolog -runall ) \
        > "$WORK/xsim_$name.out" 2>&1
    rc=$?
    t1=$(date +%s)

    line=$(/usr/bin/grep '^CSV,' "$WORK/xsim_$name.out" | head -1)
    if [ $rc -ne 0 ] || [ -z "$line" ]; then
        echo "   !! no result (rc=$rc, $((t1 - t0)) s)"
        tail -15 "$WORK/xsim_$name.out"
        echo "$name,$faza,$d,,,,,,FAIL" >> "$CSV"
        n_fail=$((n_fail + 1))
        continue
    fi

    q=$(echo "$line"      | cut -d, -f4)
    bitlen=$(echo "$line" | cut -d, -f5)
    cycles=$(echo "$line" | cut -d, -f6)
    status=$(echo "$line" | cut -d, -f7)
    fmax=$(fmax_of "$cfg")
    us=$(awk -v c="$cycles" -v f="$fmax" 'BEGIN { if (f > 0) printf "%.2f", c / f; else printf "" }')

    echo "$name,$faza,$d,$q,$bitlen,$cycles,$fmax,$us,$status" >> "$CSV"
    echo "   $cycles cycles, $status, $((t1 - t0)) s${us:+, $us us at $fmax MHz}"

    if [ "$status" = "OK" ]; then n_ok=$((n_ok + 1)); else n_fail=$((n_fail + 1)); fi
done

echo
echo "== gotovo: $n_ok OK, $n_fail nije proslo -> $CSV"
[ "$n_fail" -eq 0 ]
