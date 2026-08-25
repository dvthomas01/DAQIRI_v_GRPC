#!/usr/bin/env bash
# Evidence so far: for the gRPC arms CUPTI recorded exactly the LAST 20 CUDA
# calls of the process (all teardown, all on the main thread) and nothing from
# the worker thread that runs the FFT. CUPTI keeps per-thread activity buffers
# and saves them when they fill or at collection end. The gRPC server's worker
# thread is created by the Rust transport library and is not joined at exit, so
# its buffer is plausibly discarded rather than saved.
#
# --cuda-flush-interval forces periodic saving of all buffers, which does not
# depend on any thread living long enough to be flushed. If that is the cause,
# launches jump from 0 into the hundreds.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"
SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
PORT=50133
S=1048576
mkdir -p /tmp/proftest

clean () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null; rm -f /dev/shm/iox2_* 2>/dev/null; sleep 1
}

run () {  # run <tag> <extra nsys args...>
    local tag=$1; shift
    clean
    timeout 300 nsys profile --trace=cuda,osrt --osrt-threshold=1000 \
        --sample=none --cpuctxsw=none --force-overwrite=true "$@" \
        --output=/tmp/proftest/$tag \
        $SERVER --port $PORT --bufsize $S --n-buffers 200 --warmup 50 \
        --out /tmp/proftest/$tag.csv --transport shmem --one-shot --zero-copy \
        > /tmp/proftest/$tag.log 2>&1 &
    local sp=$!
    sleep 5
    timeout 200 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize $S --n-buffers 200 --warmup 50 --pace-us 25 >>/tmp/proftest/$tag.log 2>&1
    wait $sp 2>/dev/null
    nsys export --type sqlite --force-overwrite=true \
        --output /tmp/proftest/$tag.sqlite /tmp/proftest/$tag.nsys-rep >/dev/null 2>&1
}

run f_100ms  --cuda-flush-interval=100
run f_1000ms --cuda-flush-interval=1000
clean

python3 - <<'PY'
import sqlite3, glob, os
from collections import Counter
for p in sorted(glob.glob("/tmp/proftest/f_*.sqlite")):
    tag = os.path.basename(p)[:-7]
    cx = sqlite3.connect(p)
    T = {r[0] for r in cx.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    S = {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}
    c = Counter()
    for (nid,) in cx.execute("SELECT nameId FROM CUPTI_ACTIVITY_KIND_RUNTIME"):
        c[S.get(nid, "?")] += 1
    k = 0
    if 'CUPTI_ACTIVITY_KIND_KERNEL' in T:
        k = list(cx.execute("SELECT count(*) FROM CUPTI_ACTIVITY_KIND_KERNEL"))[0][0]
    print("%-9s launches=%-5d kernels=%-5d api=%-5d" %
          (tag, c.get('cuLaunchKernel', 0), k, sum(c.values())))
    for nm, n in c.most_common(5):
        print("        %-38s %5d" % (nm, n))
PY
