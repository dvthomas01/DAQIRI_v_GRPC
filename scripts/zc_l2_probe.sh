#!/usr/bin/env bash
# zc_l2_probe.sh — run one Level-2 (--zc-parse) shmem session and dump the
# zero-copy diagnostic (pointer + alignment) plus any cuFFT error.
set -u
cd "$HOME/daqiri_gpu"
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"
SERVER="build_grpc/bench_grpc_server"
CLIENT="build_grpc/bench_grpc_client"
BS=16384; N=200; W=20; PACE=400; PORT=50099

pkill -9 -f bench_grpc_server 2>/dev/null || true
sleep 1
rm -rf /tmp/iceoryx2 2>/dev/null || true
rm -f /dev/shm/iox2_* 2>/dev/null || true
sleep 1

"$SERVER" --port "$PORT" --bufsize "$BS" --n-buffers "$N" --warmup "$W" \
          --out /tmp/zc_l2.csv --transport shmem --one-shot --zc-parse --verify \
          >/tmp/zc_l2_srv.log 2>&1 &
SPID=$!
sleep 4
"$CLIENT" --server "localhost:$PORT" --transport shmem \
          --bufsize "$BS" --n-buffers "$N" --warmup "$W" --pace-us "$PACE" \
          >/tmp/zc_l2_cli.log 2>&1
wait $SPID 2>/dev/null || true

echo "=== diagnostic ==="
grep -nE "zero-copy|L2 span|L1 reused|cuFFT error|verify|PASSED|no measured" /tmp/zc_l2_srv.log
echo "ZC_L2_DONE"
