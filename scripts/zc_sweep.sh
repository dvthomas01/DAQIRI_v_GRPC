#!/usr/bin/env bash
# zc_sweep.sh [PACE] [TRIALS]
# Matched copy-vs-zero-copy sweep on the shmem transport.  For every buffer
# size we run TRIALS repeats of the copy path (staging + cudaMemcpy) and the
# zero-copy path (--zero-copy: coherent in-place, no H->D copy), paced
# identically so the GPU clock state is the same for each.  Every trial CSV is
# written as data/zcs_<mode>_<BS>_<trial>.csv  (mode in {copy, zerocopy}).
set -u
cd "$HOME/daqiri_gpu"

SERVER="build_grpc/bench_grpc_server"
CLIENT="build_grpc/bench_grpc_client"
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

PACE=${1:-400}
TRIALS=${2:-3}
PORT=50096
N=1000; W=100

run_one () {
    local BS=$1 MODE=$2 CSV=$3
    local ZC=""
    [ "$MODE" = "zerocopy" ] && ZC="--zero-copy"
    pkill -9 -f bench_grpc_server 2>/dev/null || true
    sleep 1
    rm -rf /tmp/iceoryx2 2>/dev/null || true
    rm -f /dev/shm/iox2_* 2>/dev/null || true
    rm -f "$CSV"
    sleep 1
    "$SERVER" --port "$PORT" --bufsize "$BS" --n-buffers "$N" --warmup "$W" \
              --out "$CSV" --transport shmem --one-shot $ZC >/dev/null 2>&1 &
    local SPID=$!
    sleep 4
    "$CLIENT" --server "localhost:$PORT" --transport shmem \
              --bufsize "$BS" --n-buffers "$N" --warmup "$W" --pace-us "$PACE" >/dev/null 2>&1
    wait $SPID 2>/dev/null || true
}

echo "=== copy vs zero-copy sweep  pace=${PACE}us  trials=${TRIALS}  N=${N} W=${W} ==="
for BS in 4096 8192 16384 32768; do
    for MODE in copy zerocopy; do
        for TRIAL in $(seq 1 "$TRIALS"); do
            CSV="data/zcs_${MODE}_${BS}_${TRIAL}.csv"
            echo "  run BS=$BS mode=$MODE trial=$TRIAL"
            run_one "$BS" "$MODE" "$CSV"
        done
    done
done
pkill -9 -f bench_grpc_server 2>/dev/null || true
echo "ALLDONE"
