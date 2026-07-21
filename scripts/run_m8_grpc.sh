#!/bin/bash
# run_m8_grpc.sh — M8 Pipeline B transport comparison sweep.
#
# Runs bench_grpc_server / bench_grpc_client (grpc-direct linked) with the
# requested transport (default: shmem).  Results land in
# data/grpc_<TRANSPORT>_pipeline_<BS>.csv so they don't overwrite M7 standard
# results.
#
# Usage:
#   bash scripts/run_m8_grpc.sh [--transport shmem|tcp|tcp_low_latency]
set -e

TRANSPORT="${1:-shmem}"
for arg in "$@"; do
    if [[ "$arg" == "--transport" ]]; then shift; TRANSPORT="$1"; fi
done

BUILD_DIR="$HOME/daqiri_gpu/build_grpc"
GD_LIB="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release"

SERVER="$BUILD_DIR/bench_grpc_server"
CLIENT="$BUILD_DIR/bench_grpc_client"

# libgrpc_direct.so is in RPATH of the binaries, but set LD_LIBRARY_PATH as
# belt-and-suspenders for dynamic linker on some kernel configurations.
export LD_LIBRARY_PATH="$GD_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

PORT=50053        # different port from M7 (50052) to avoid stale listeners
N_BUFFERS=1000
WARMUP=100

if [[ ! -x "$SERVER" ]]; then
    echo "ERROR: $SERVER not found. Run: cmake --build ~/daqiri_gpu/build_grpc --parallel 16"
    exit 1
fi

echo "============================================"
echo " M8 — Pipeline B Transport Comparison Sweep"
echo "  transport : $TRANSPORT"
echo "  n_buffers : $N_BUFFERS  warmup: $WARMUP"
echo "  CSV prefix: grpc_${TRANSPORT}_pipeline_*"
echo "============================================"

# ── Quick smoke-test: 1 buffer, no warmup, 4096 samples ─────────────────────
# Verifies shmem session handshake before committing to full sweep.
echo ""
echo "── smoke test (1 buffer, 4096 samples) ──"
SMOKE_CSV="data/grpc_${TRANSPORT}_smoke.csv"

pkill -f bench_grpc_server 2>/dev/null || true
rm -rf /tmp/iceoryx2 2>/dev/null || true
sleep 1

"$SERVER" \
    --port       "$PORT" \
    --bufsize    4096 \
    --n-buffers  1 \
    --warmup     0 \
    --out        "$SMOKE_CSV" \
    --transport  "$TRANSPORT" \
    --one-shot \
    &
SMOKE_PID=$!
sleep 5

"$CLIENT" \
    --server    "localhost:$PORT" \
    --transport "$TRANSPORT" \
    --bufsize   4096 \
    --n-buffers 1 \
    --warmup    0

wait $SMOKE_PID 2>/dev/null || true
pkill -f bench_grpc_server 2>/dev/null || true
sleep 1
echo "  smoke test complete — transport handshake OK"
echo ""

cd "$HOME/daqiri_gpu"
mkdir -p data

# ── Full sweep ───────────────────────────────────────────────────────────────
for BS in 4096 8192 16384 32768; do
    echo "── bufsize = $BS samples ($((BS * 4 / 1024)) KB) ──"

    # Ensure no server from the previous size is still alive AND clear stale
    # iceoryx2 shared-memory nodes.  Servers core-dump on shutdown without
    # releasing their iceoryx2 resources; the leftover segments degrade the
    # shmem ring for the next size and roughly quintuple the measured H->D
    # latency (18us -> 104us).  A clean /tmp/iceoryx2 restores 18us.
    pkill -f bench_grpc_server 2>/dev/null || true
    sleep 1
    rm -rf /tmp/iceoryx2 2>/dev/null || true
    sleep 1

    CSV="data/grpc_${TRANSPORT}_pipeline_${BS}.csv"

    "$SERVER" \
        --port       "$PORT" \
        --bufsize    "$BS" \
        --n-buffers  "$N_BUFFERS" \
        --warmup     "$WARMUP" \
        --out        "$CSV" \
        --transport  "$TRANSPORT" \
        --one-shot \
        &
    SERVER_PID=$!

    sleep 4

    "$CLIENT" \
        --server    "localhost:$PORT" \
        --transport "$TRANSPORT" \
        --bufsize   "$BS" \
        --n-buffers "$N_BUFFERS" \
        --warmup    "$WARMUP"

    wait $SERVER_PID 2>/dev/null || true
    pkill -f bench_grpc_server 2>/dev/null || true
    sleep 1
    rm -rf /tmp/iceoryx2 2>/dev/null || true
    echo ""
done

echo "============================================"
echo " M8 sweep complete."
echo " CSVs: data/grpc_${TRANSPORT}_pipeline_*.csv"
echo "============================================"
