#!/usr/bin/env bash
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"
pkill -9 -f bench_grpc 2>/dev/null
rm -rf /tmp/iceoryx2 2>/dev/null; rm -f /dev/shm/iox2_* 2>/dev/null
rm -f /tmp/s.csv /tmp/g.log
sleep 1
timeout 90 build_grpc/bench_grpc_server --port 50097 --bufsize 4096 --n-buffers 200 \
    --warmup 50 --out /tmp/s.csv --transport shmem --one-shot >/tmp/g.log 2>&1 &
SPID=$!
sleep 4
timeout 60 taskset -c 11 build_grpc/bench_grpc_client --server localhost:50097 \
    --transport shmem --bufsize 4096 --n-buffers 200 --warmup 50 --pace-us 400 >>/tmp/g.log 2>&1
wait $SPID 2>/dev/null
echo "=== summary ==="
grep -aE 'PASSED|FAILED|E2E|p50|p99|Throughput|rror' /tmp/g.log | head -25
echo "ROWS=$(awk 'END{print NR-1}' /tmp/s.csv 2>/dev/null)"
