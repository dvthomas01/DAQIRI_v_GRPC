#!/usr/bin/env bash
# Phase 0 — attribute the gRPC zero-copy residual (e2e - fft_exec).
#
# The 4 MB sweep shows gRPC's residual growing 8.1 us (16 KB) -> 81.5 us (4 MB)
# while DAQiri RoCE's stays flat at ~4.9 us.  Leading hypothesis: the device
# pointer cache in bench_grpc_server.cc is keyed on the exact `src` pointer, and
# grpc-direct hands the handler a fresh BufferRequest per message, so we call
# cudaHostRegister on the whole payload every single message.
#
# This runs the SAME invocation as scripts/grpc_sweep.sh (N=200 W=50 pace=400,
# shmem, --zero-copy) but adds --stage-timing, at three representative sizes.
# Writes to data/p0_* so the existing sweep CSVs are untouched.
#
# Decisive output: "register rate : NN % of messages" + VERDICT line.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
SIZES="${SIZES:-4096 65536 1048576}"
N=200; W=50; PACE=400; PORT=50098

clean_shmem () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

# Guard against a second sweep racing us (cross-kills the server, corrupts rows).
if pgrep -af 'grpc_sweep|ab_airtight_sweep' >/dev/null 2>&1; then
    echo "ABORT: another sweep is running:"; pgrep -af 'grpc_sweep|ab_airtight_sweep'
    exit 1
fi

clean_shmem
for S in $SIZES; do
    KB=$(( S * 4 / 1024 ))
    CSV="data/p0_zerocopy_${S}.csv"
    LOG="/tmp/p0_zerocopy_${S}.log"
    clean_shmem
    rm -f "$CSV"
    echo "================================================================"
    echo "=== Phase 0  size=$S samples (${KB} KB)  N=$N W=$W pace=${PACE}us"
    echo "================================================================"
    timeout 120 $SERVER --port $PORT --bufsize $S --n-buffers $N --warmup $W \
        --out "$CSV" --transport shmem --one-shot --zero-copy --stage-timing \
        >"$LOG" 2>&1 &
    SPID=$!
    sleep 4
    timeout 100 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize $S --n-buffers $N --warmup $W --pace-us $PACE >>"$LOG" 2>&1
    wait $SPID 2>/dev/null

    # The attribution block plus the headline percentiles.
    sed -n '/Phase 0: zero-copy residual attribution/,/^-----/p' "$LOG"
    grep -aE 'E2E p50|cuFFT p50|n_measured|zero-copy\]' "$LOG" | head -6
    echo
done
clean_shmem
echo ALLDONE
