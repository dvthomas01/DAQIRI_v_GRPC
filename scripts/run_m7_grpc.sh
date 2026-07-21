#!/bin/bash
# run_m7_grpc.sh — Pipeline B sweep: gRPC Direct → H→D → cuFFT.
#
# For each buffer size, starts bench_grpc_server, runs bench_grpc_client
# (shmem transport), prints results and generates figures.
#
# Usage: bash scripts/run_m7_grpc.sh [--transport shmem|tcp|standard]
set -e

TRANSPORT="${1:-shmem}"
# Override with --transport flag
for arg in "$@"; do
    if [[ "$arg" == "--transport" ]]; then shift; TRANSPORT="$1"; fi
done

BUILD_DIR="$HOME/daqiri_gpu/build_grpc"
# Standard gRPC uses separate binaries that never load libgrpc_direct.so.
# The Rust library registers a global transport filter that intercepts ALL
# connections (client and server side); the _std binaries are compiled without
# that linkage so the filter is never installed.
if [[ "$TRANSPORT" == "standard" ]]; then
    SERVER="$BUILD_DIR/bench_grpc_server_std"
    CLIENT="$BUILD_DIR/bench_grpc_client_std"
else
    SERVER="$BUILD_DIR/bench_grpc_server"
    CLIENT="$BUILD_DIR/bench_grpc_client"
fi
PORT=50052
N_BUFFERS=1000
WARMUP=100

if [[ ! -x "$SERVER" ]]; then
    echo "ERROR: $SERVER not found. Run: bash scripts/build_grpc.sh first"
    exit 1
fi

echo "============================================"
echo " M7 — Pipeline B Sweep (gRPC Direct)"
echo "  transport : $TRANSPORT"
echo "  n_buffers : $N_BUFFERS  warmup: $WARMUP"
echo "============================================"

cd "$HOME/daqiri_gpu"
mkdir -p data

for BS in 4096 8192 16384 32768; do
    echo ""
    echo "── bufsize = $BS samples ($((BS * 4 / 1024)) KB) ──"

    CSV="data/grpc_pipeline_${BS}.csv"

    # Start server in background
    "$SERVER" \
        --bufsize    "$BS" \
        --n-buffers  "$N_BUFFERS" \
        --warmup     "$WARMUP" \
        --out        "$CSV" \
        --transport  "$TRANSPORT" \
        --one-shot \
        &
    SERVER_PID=$!

    # Give server time to bind port and warm up CUDA
    sleep 4

    # Run client
    "$CLIENT" \
        --server    "localhost:$PORT" \
        --transport "$TRANSPORT" \
        --bufsize   "$BS" \
        --n-buffers "$N_BUFFERS" \
        --warmup    "$WARMUP"

    # Wait for server to finish (one-shot auto-shuts down after call)
    wait $SERVER_PID 2>/dev/null || true
    echo ""
done

echo "============================================"
echo " Sweep complete. Generating M7 figures..."
echo "============================================"
source ~/grpc-bench-env/bin/activate
python3 scripts/plot_m7_grpc.py --data data --out data/figures

echo ""
echo "==== M7 COMPLETE ===="
