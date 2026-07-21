#!/usr/bin/env bash
# matched_compare.sh [PACE] [TRIALS]
# Fair M8(shmem) vs M7(standard) comparison: BOTH transports paced identically
# so the GPU clock state — and therefore the transport-independent H->D
# cudaMemcpy — is the same for each.  Runs TRIALS repeats per (size,transport)
# and writes every trial's CSV as data/mc_<transport>_<BS>_<trial>.csv.
set -u
cd "$HOME/daqiri_gpu"

SERVER="build_grpc/bench_grpc_server"
CLIENT="build_grpc/bench_grpc_client"
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

PACE=${1:-400}
TRIALS=${2:-3}
PORT=50097
N=1000; W=100

run_one () {
    local BS=$1 TR=$2 TRIAL=$3 CSV=$4
    pkill -9 -f bench_grpc_server 2>/dev/null || true
    sleep 1
    rm -rf /tmp/iceoryx2 2>/dev/null || true
    rm -f /dev/shm/iox2_* 2>/dev/null || true
    rm -f "$CSV"
    sleep 1
    "$SERVER" --port "$PORT" --bufsize "$BS" --n-buffers "$N" --warmup "$W" \
              --out "$CSV" --transport "$TR" --one-shot >/dev/null 2>&1 &
    local SPID=$!
    sleep 4
    "$CLIENT" --server "localhost:$PORT" --transport "$TR" \
              --bufsize "$BS" --n-buffers "$N" --warmup "$W" --pace-us "$PACE" >/dev/null 2>&1
    wait $SPID 2>/dev/null || true
}

echo "=== Matched-pace comparison  pace=${PACE}us  trials=${TRIALS}  N=${N} W=${W} ==="
for BS in 4096 8192 16384 32768; do
    for TR in standard shmem; do
        for TRIAL in $(seq 1 "$TRIALS"); do
            CSV="data/mc_${TR}_${BS}_${TRIAL}.csv"
            run_one "$BS" "$TR" "$TRIAL" "$CSV"
        done
    done
done
echo "ALLDONE"
