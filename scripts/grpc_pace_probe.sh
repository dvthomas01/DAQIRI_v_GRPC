#!/usr/bin/env bash
# grpc_pace_probe.sh — find the fastest STABLE pace for the gRPC shmem transport.
# For each PACE in the list, run server+client once (with a hard timeout so a
# stall can't hang) and report how many measured rows landed. 0 = unpaced.
set -u
cd "$HOME/daqiri_gpu"
SERVER="build_grpc/bench_grpc_server"
CLIENT="build_grpc/bench_grpc_client"
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"
PORT=50097; BS=4096; N=1000; W=100
USE_TASKSET=${1:-none}   # "none" or "pin"

for PACE in 0 10 25 50 100 200; do
    CSV="/tmp/probe_${PACE}.csv"
    rm -f "$CSV"
    pkill -9 -f bench_grpc 2>/dev/null || true
    sleep 1
    rm -rf /tmp/iceoryx2 2>/dev/null || true; rm -f /dev/shm/iox2_* 2>/dev/null || true
    sleep 1
    if [ "$USE_TASKSET" = "pin" ]; then
        timeout 45 taskset -c 9 "$SERVER" --port "$PORT" --bufsize "$BS" --n-buffers "$N" \
            --warmup "$W" --out "$CSV" --transport shmem --one-shot >/dev/null 2>&1 &
    else
        timeout 45 "$SERVER" --port "$PORT" --bufsize "$BS" --n-buffers "$N" \
            --warmup "$W" --out "$CSV" --transport shmem --one-shot >/dev/null 2>&1 &
    fi
    SPID=$!
    sleep 4
    if [ "$USE_TASKSET" = "pin" ]; then
        timeout 40 taskset -c 11 "$CLIENT" --server "localhost:$PORT" --transport shmem \
            --bufsize "$BS" --n-buffers "$N" --warmup "$W" --pace-us "$PACE" >/dev/null 2>&1
    else
        timeout 40 "$CLIENT" --server "localhost:$PORT" --transport shmem \
            --bufsize "$BS" --n-buffers "$N" --warmup "$W" --pace-us "$PACE" >/dev/null 2>&1
    fi
    CRC=$?
    wait $SPID 2>/dev/null; SRC=$?
    ROWS=0; [ -f "$CSV" ] && ROWS=$(( $(wc -l < "$CSV") - 1 ))
    STALL="ok"; [ "$SRC" = "124" ] && STALL="SERVER_TIMEOUT"; [ "$CRC" = "124" ] && STALL="CLIENT_TIMEOUT"
    printf "pace=%-4s taskset=%-4s rows=%-5s %s\n" "$PACE" "$USE_TASKSET" "$ROWS" "$STALL"
done
pkill -9 -f bench_grpc 2>/dev/null || true
echo PROBEDONE
