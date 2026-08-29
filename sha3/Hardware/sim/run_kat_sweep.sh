#!/bin/bash
# KAT sweep for sha3_axis_ip: all SHA3 variants x DATA_WIDTH x ROUNDS_PER_CYCLE.
# SHA3-224 skips DW=64 (224/64 is not an integer -> OutputBuffer cannot emit
# the full digest; known design limitation, not a bug to test against).
set -e
SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SIM_DIR/../src"
BUILD_DIR="${1:-/tmp/sha3_kat}"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

GHDL_FLAGS="--std=08 -fsynopsys"

ghdl -a $GHDL_FLAGS \
    "$SRC_DIR/keccak_pkg.vhd" \
    "$SRC_DIR/sha3_input_buffer.vhd" \
    "$SRC_DIR/keccak_sponge.vhd" \
    "$SRC_DIR/sha3_output_buffer.vhd" \
    "$SRC_DIR/sha3_top.vhd" \
    "$SRC_DIR/sha3_axis_ip.vhd" \
    "$SIM_DIR/tb_sha3_vectors_pkg.vhd" \
    "$SIM_DIR/tb_sha3_kat.vhd"

ghdl -e $GHDL_FLAGS tb_sha3_kat

PASS=0
FAIL=0
for VER in 224 256 384 512; do
    if [ "$VER" = "224" ]; then DWS="16 32"; else DWS="8 32 64"; fi
    if [ "$VER" = "256" ]; then RPCS="1 2 3 4 6 8 12 24"; else RPCS="1 2"; fi
    for DW in $DWS; do
        for RPC in $RPCS; do
            TAG="SHA3-${VER}_DW${DW}_RPC${RPC}"
            if ghdl -r $GHDL_FLAGS tb_sha3_kat \
                    -gG_VERSION="$VER" -gG_DATA_WIDTH="$DW" -gG_ROUNDS_PER_CYCLE="$RPC" \
                    --stop-time=2ms > "$BUILD_DIR/$TAG.log" 2>&1; then
                if grep -q "ALL 4 PASS" "$BUILD_DIR/$TAG.log"; then
                    echo "PASS  $TAG"; PASS=$((PASS+1))
                else
                    echo "FAIL  $TAG (no ALL-PASS line)"; FAIL=$((FAIL+1))
                fi
            else
                echo "FAIL  $TAG"; FAIL=$((FAIL+1))
                grep -E "FAIL|TIMEOUT|error" "$BUILD_DIR/$TAG.log" | head -5
            fi
        done
    done
done

# SHAKE KAT: 4 messages vs hashlib shake_128/256, single- and multi-chunk
# squeeze (OUT_BITS > rate forces re-permutation between chunks)
ghdl -a $GHDL_FLAGS "$SIM_DIR/tb_shake_kat.vhd"
ghdl -e $GHDL_FLAGS tb_shake_kat
cp "$SIM_DIR"/shake*_kat_*.txt "$BUILD_DIR/"

for CFG in "128 512 32 1" "128 4096 32 2" "128 4096 64 1" \
           "256 1024 32 1" "256 1024 8 2" "256 8192 64 1"; do
    set -- $CFG
    TAG="SHAKE${1}_OUT${2}_DW${3}_RPC${4}"
    if ghdl -r $GHDL_FLAGS tb_shake_kat -gG_SHAKE_VERSION=$1 -gG_OUT_BITS=$2 \
            -gG_DATA_WIDTH=$3 -gG_ROUNDS_PER_CYCLE=$4 \
            -gG_VECTOR_FILE="shake${1}_kat_${2}.txt" \
            --stop-time=5ms > "$BUILD_DIR/$TAG.log" 2>&1 \
       && grep -q "ALL 4 PASS" "$BUILD_DIR/$TAG.log"; then
        echo "PASS  $TAG"; PASS=$((PASS+1))
    else
        echo "FAIL  $TAG"; FAIL=$((FAIL+1))
        grep -E "FAIL|TIMEOUT|error" "$BUILD_DIR/$TAG.log" | head -3
    fi
done

# cSHAKE/KMAC KAT: message = SW-formatted bytes (N/S prefix block, KMAC key
# block + right_encode(L)); HW difference is only the 0x04 pad byte
ghdl -a $GHDL_FLAGS "$SIM_DIR/tb_cshake_kat.vhd"
ghdl -e $GHDL_FLAGS tb_cshake_kat
cp "$SIM_DIR"/cshake*_kat_*.txt "$BUILD_DIR/"

for CFG in "256 512 4 32 1" "256 2048 2 32 2" "128 512 1 64 1"; do
    set -- $CFG
    TAG="CSHAKE${1}_OUT${2}_DW${4}_RPC${5}"
    if ghdl -r $GHDL_FLAGS tb_cshake_kat -gG_SHAKE_VERSION=$1 -gG_OUT_BITS=$2 \
            -gG_NUM_CASES=$3 -gG_DATA_WIDTH=$4 -gG_ROUNDS_PER_CYCLE=$5 \
            -gG_VECTOR_FILE="cshake${1}_kat_${2}.txt" \
            --stop-time=5ms > "$BUILD_DIR/$TAG.log" 2>&1 \
       && grep -q "PASS (cSHAKE" "$BUILD_DIR/$TAG.log"; then
        echo "PASS  $TAG"; PASS=$((PASS+1))
    else
        echo "FAIL  $TAG"; FAIL=$((FAIL+1))
        grep -E "FAIL|TIMEOUT|error" "$BUILD_DIR/$TAG.log" | head -3
    fi
done

# Length sweep (every message length 1..160, SHA3-256) + dense back-to-back
# stress with output backpressure (tb_sha3_dense)
ghdl -a $GHDL_FLAGS "$SIM_DIR/tb_sha3_len_sweep.vhd" "$SIM_DIR/tb_sha3_dense.vhd"
ghdl -e $GHDL_FLAGS tb_sha3_len_sweep
ghdl -e $GHDL_FLAGS tb_sha3_dense
cp "$SIM_DIR/len_sweep_sha3_256.txt" "$SIM_DIR/len_sweep_shake256_1024.txt" \
   "$SIM_DIR/len_sweep_shake128_4096.txt" "$BUILD_DIR/"

for DW in 8 16 32 64; do
    TAG="LEN-SWEEP_DW${DW}"
    if ghdl -r $GHDL_FLAGS tb_sha3_len_sweep -gG_DATA_WIDTH=$DW \
            --stop-time=10ms > "$BUILD_DIR/$TAG.log" 2>&1 \
       && grep -q "ALL 160 PASS" "$BUILD_DIR/$TAG.log"; then
        echo "PASS  $TAG"; PASS=$((PASS+1))
    else
        echo "FAIL  $TAG"; FAIL=$((FAIL+1))
    fi
done

for CFG in "32 0 1" "32 1 1" "64 1 1" "8 1 2" "32 1 24"; do
    set -- $CFG
    TAG="DENSE_DW${1}_STALL${2}_RPC${3}"
    if ghdl -r $GHDL_FLAGS tb_sha3_dense -gG_DATA_WIDTH=$1 -gG_STALL=$2 \
            -gG_ROUNDS_PER_CYCLE=$3 --stop-time=30ms > "$BUILD_DIR/$TAG.log" 2>&1 \
       && grep -q "ALL 160 PASS" "$BUILD_DIR/$TAG.log"; then
        echo "PASS  $TAG"; PASS=$((PASS+1))
    else
        echo "FAIL  $TAG"; FAIL=$((FAIL+1))
    fi
done

# Pipeline-overlap proof: absorb || permute, squeeze || drain (gapless
# burst), input || output -- cycle-counter based (tb_sha3_overlap)
ghdl -a $GHDL_FLAGS "$SIM_DIR/tb_sha3_overlap.vhd"
ghdl -e $GHDL_FLAGS tb_sha3_overlap
cp "$SIM_DIR/overlap_shake256_8192.txt" "$BUILD_DIR/"
if ghdl -r $GHDL_FLAGS tb_sha3_overlap --stop-time=5ms \
        > "$BUILD_DIR/OVERLAP.log" 2>&1 \
   && grep -q "ALL 3 OVERLAPS CONFIRMED" "$BUILD_DIR/OVERLAP.log"; then
    echo "PASS  OVERLAP"; PASS=$((PASS+1))
else
    echo "FAIL  OVERLAP"; FAIL=$((FAIL+1))
    grep -E "FAIL|TIMEOUT" "$BUILD_DIR/OVERLAP.log" | head -3
fi

# SHAKE length sweep + dense (multi-squeeze under dense traffic + stall)
for CFG in "LEN-SWEEP-SHAKE256-1024 tb_sha3_len_sweep 256 1024 32 1 0 len_sweep_shake256_1024.txt" \
           "DENSE-SHAKE256-1024     tb_sha3_dense     256 1024 32 1 1 len_sweep_shake256_1024.txt" \
           "DENSE-SHAKE128-4096     tb_sha3_dense     128 4096 32 2 1 len_sweep_shake128_4096.txt"; do
    set -- $CFG
    TAG="$1"; TB="$2"; VER="$3"; BITS="$4"; DW="$5"; RPC="$6"; STALL="$7"; VEC="$8"
    if [ "$TB" = "tb_sha3_dense" ]; then EXTRA="-gG_STALL=$STALL"; else EXTRA=""; fi
    if ghdl -r $GHDL_FLAGS $TB -gG_ALGORITHM=SHAKE -gG_SHAKE_VERSION=$VER \
            -gG_OUT_BITS=$BITS -gG_DATA_WIDTH=$DW -gG_ROUNDS_PER_CYCLE=$RPC \
            $EXTRA -gG_VECTOR_FILE="$VEC" \
            --stop-time=60ms > "$BUILD_DIR/$TAG.log" 2>&1 \
       && grep -q "ALL 160 PASS" "$BUILD_DIR/$TAG.log"; then
        echo "PASS  $TAG"; PASS=$((PASS+1))
    else
        echo "FAIL  $TAG"; FAIL=$((FAIL+1))
        grep -E "FAIL|TIMEOUT|error" "$BUILD_DIR/$TAG.log" | head -3
    fi
done

echo "----------------------------------------"
echo "SWEEP: $PASS pass, $FAIL fail (logs in $BUILD_DIR)"
[ "$FAIL" -eq 0 ]
