#!/usr/bin/env bash
# GHDL build+run for tb_AES_multicore_wrapper (VHDL-2008).
# Usage: ./run_ghdl.sh            (3 backpressure configs)
#        ./run_ghdl.sh wave       (30/70 config, dump wave.ghw)
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"          # the testbenches read data/inData.txt relative to the cwd
SRC="$HERE/../src"
STD=--std=08
WORK=--workdir="$HERE/work"
mkdir -p "$HERE/work"

ghdl -a $STD $WORK "$SRC/aes_pkg.vhd"
ghdl -a $STD $WORK "$SRC/aes_round_column.vhd"
ghdl -a $STD $WORK "$SRC/aes_round.vhd"
ghdl -a $STD $WORK "$SRC/key_expansion.vhd"
ghdl -a $STD $WORK "$SRC/aes_enc_rolled.vhd"
ghdl -a $STD $WORK "$SRC/AES_multicore_wrapper.vhd"
ghdl -a $STD $WORK "$HERE/tb_AES_multicore_wrapper.vhd"

ghdl -e $STD $WORK tb_AES_multicore_wrapper

run_cfg () {   # $1=valid%  $2=ready%  $3=stop-time
    echo "============================================================"
    echo ">>> CONFIG  valid=$1%  ready=$2%"
    echo "============================================================"
    ghdl -r $STD $WORK tb_AES_multicore_wrapper \
        -gC_VALID_PCT=$1 -gC_READY_PCT=$2 \
        --stop-time=$3 --ieee-asserts=disable-at-0 2>&1 \
        | grep -v metavalue \
        | grep -E "SUMMARY|valid/ready|packets|blocks |pulses|errors|RESULT|MISMATCH|STALL|X/U|COUNT|TIMEOUT"
}

if [ "$1" == "wave" ]; then
    ghdl -r $STD $WORK tb_AES_multicore_wrapper \
        -gC_VALID_PCT=30 -gC_READY_PCT=70 \
        --wave="$HERE/wave.ghw" --stop-time=40ms --ieee-asserts=disable-at-0
else
    run_cfg 100 100 20ms
    run_cfg 30  70  40ms
    run_cfg 70  30  40ms
fi
