#!/usr/bin/env bash
# The opt/base server produced a trace containing ONLY teardown CUDA calls.
# Three candidate causes, tested in one pass so we pick by evidence:
#
#   v1 fork    the process forks/execs and the CUDA work happens in a child
#              that nsys does not follow by default
#   v2 osrt    the OS-runtime trace volume starves CUPTI and GPU-side records
#              are dropped (this arm is the CPU-heaviest of the four)
#   v3 delay   CUPTI attaches late, so only the tail of the run is captured
#              (tested by profiling a LONGER run: if the captured fraction is
#              constant the cause is drops, if it is a fixed tail it is delay)
#
# Decisive output is the cuLaunchKernel count. The unprofiled run measures
# ~200 messages, so a healthy trace should show launches in the hundreds.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"
SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
PORT=50131
S=1048576
mkdir -p /tmp/proftest

clean () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null; rm -f /dev/shm/iox2_* 2>/dev/null; sleep 1
}

run () {  # run <tag> <n> <extra nsys args...>
    local tag=$1; shift
    local n=$1; shift
    clean
    timeout 300 nsys profile "$@" --force-overwrite=true \
        --output=/tmp/proftest/$tag \
        $SERVER --port $PORT --bufsize $S --n-buffers $n --warmup 50 \
        --out /tmp/proftest/$tag.csv --transport shmem --one-shot --zero-copy \
        > /tmp/proftest/$tag.log 2>&1 &
    local sp=$!
    sleep 5
    timeout 200 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize $S --n-buffers $n --warmup 50 --pace-us 25 >>/tmp/proftest/$tag.log 2>&1
    wait $sp 2>/dev/null
    nsys export --type sqlite --force-overwrite=true \
        --output /tmp/proftest/$tag.sqlite /tmp/proftest/$tag.nsys-rep >/dev/null 2>&1
}

run v1_fork   200 --trace=cuda,osrt --osrt-threshold=1000 --sample=none --cpuctxsw=none --trace-fork-before-exec=true
run v2_nosrt  200 --trace=cuda --sample=none --cpuctxsw=none
run v3_long   600 --trace=cuda --sample=none --cpuctxsw=none
clean

python3 - <<'PY'
import sqlite3, glob, os
from collections import Counter
for p in sorted(glob.glob("/tmp/proftest/v*.sqlite")):
    tag = os.path.basename(p)[:-7]
    try:
        cx = sqlite3.connect(p)
        T = {r[0] for r in cx.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        S = {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}
        c = Counter()
        pids = set()
        for nid, gp in cx.execute("SELECT nameId, globalPid FROM CUPTI_ACTIVITY_KIND_RUNTIME"):
            c[S.get(nid, "?")] += 1
            pids.add(gp)
        k = 0
        if 'CUPTI_ACTIVITY_KIND_KERNEL' in T:
            k = list(cx.execute("SELECT count(*) FROM CUPTI_ACTIVITY_KIND_KERNEL"))[0][0]
        print("%-10s launches=%-6d kernels=%-6d apicalls=%-6d pids=%d  kerneltable=%s"
              % (tag, c.get('cuLaunchKernel', 0) + c.get('cudaLaunchKernel_v7000', 0),
                 k, sum(c.values()), len(pids),
                 'CUPTI_ACTIVITY_KIND_KERNEL' in T))
    except Exception as e:
        print("%-10s cannot read: %s" % (tag, e))
PY

echo
echo "--- did the runs actually measure messages? ---"
for t in v1_fork v2_nosrt v3_long; do
    printf "%-10s %s\n" "$t" "$(grep -aoE 'n_measured=[0-9]+' /tmp/proftest/$t.log | head -1)"
done
