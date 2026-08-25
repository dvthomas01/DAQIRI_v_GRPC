#!/usr/bin/env bash
# CUPTI went silent for the whole session then recorded teardown perfectly.
# That pattern means activity tracing was turned off and back on, so look for
# something in the binary or the grpc-direct stack that calls the CUDA
# profiler-control API. cudaProfilerStop() disables CUPTI activity collection
# and nsys re-flushes at exit, which would reproduce exactly what we see.
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
cd "$HOME/daqiri_gpu" || exit 1
SO="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release/libgrpc_direct.so"

echo "=== profiler-control symbols referenced by the server binary ==="
nm -D --undefined-only build_grpc/bench_grpc_server 2>/dev/null \
    | grep -i -e profiler -e cupti
echo "  (empty above means the server binary itself never calls it)"

echo
echo "=== profiler-control symbols in libgrpc_direct.so ==="
ls -l "$SO" 2>&1 | awk '{print "  ", $5, $9}'
nm -D "$SO" 2>/dev/null | grep -i -e profiler -e cupti
strings -a "$SO" 2>/dev/null | grep -i -e cudaProfiler -e cuProfiler -e cupti | sort -u | head
echo "  (empty above means the transport library never calls it either)"

echo
echo "=== does the same binary trace correctly on the plain gRPC path? ==="
# If standard gRPC over TCP traces fine, CUPTI works in this binary and the
# blindness is specific to the grpc-direct shmem path.
pkill -9 -f bench_grpc_server 2>/dev/null; pkill -9 -f bench_grpc_client 2>/dev/null
rm -rf /tmp/iceoryx2 2>/dev/null; rm -f /dev/shm/iox2_* 2>/dev/null; sleep 1
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"
PORT=50137
timeout 200 nsys profile --trace=cuda --sample=none --cpuctxsw=none \
    --force-overwrite=true --output=/tmp/proftest/tcp \
    build_grpc/bench_grpc_server --port $PORT --bufsize 1048576 --n-buffers 200 \
    --warmup 50 --out /tmp/proftest/tcp.csv --transport grpc --one-shot \
    > /tmp/proftest/tcp.log 2>&1 &
SP=$!
sleep 5
timeout 120 taskset -c 11 build_grpc/bench_grpc_client --server "localhost:$PORT" \
    --transport grpc --bufsize 1048576 --n-buffers 200 --warmup 50 --pace-us 25 \
    >> /tmp/proftest/tcp.log 2>&1
wait $SP 2>/dev/null
pkill -9 -f bench_grpc_server 2>/dev/null
nsys export --type sqlite --force-overwrite=true \
    --output /tmp/proftest/tcp.sqlite /tmp/proftest/tcp.nsys-rep >/dev/null 2>&1

python3 - <<'PY'
import sqlite3
from collections import Counter
cx = sqlite3.connect("/tmp/proftest/tcp.sqlite")
T = {r[0] for r in cx.execute("SELECT name FROM sqlite_master WHERE type='table'")}
S = {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}
c = Counter()
for (nid,) in cx.execute("SELECT nameId FROM CUPTI_ACTIVITY_KIND_RUNTIME"):
    c[S.get(nid, "?")] += 1
k = list(cx.execute("SELECT count(*) FROM CUPTI_ACTIVITY_KIND_KERNEL"))[0][0] \
    if 'CUPTI_ACTIVITY_KIND_KERNEL' in T else 0
print("  plain gRPC/TCP: launches=%d kernels=%d api=%d"
      % (c.get('cuLaunchKernel', 0), k, sum(c.values())))
PY
grep -aoE 'n_measured=[0-9]+|Buffers processed : [0-9]+' /tmp/proftest/tcp.log | head -2
