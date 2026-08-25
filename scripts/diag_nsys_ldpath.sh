#!/usr/bin/env bash
# Remaining difference between the traceable and untraceable runs: the gRPC arms
# export LD_LIBRARY_PATH pointing at the Rust cargo target dir, and the DAQiri
# arm does not. nsys injects through its own preloaded libraries, so a
# LD_LIBRARY_PATH that shadows or reorders them is a plausible culprit.
# Warm-up only, no client needed, so this is quick.
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
cd "$HOME/daqiri_gpu" || exit 1
pkill -9 -f bench_grpc_server 2>/dev/null; sleep 1

probe () {  # probe <tag>
    nsys profile --trace=cuda --sample=none --cpuctxsw=none --force-overwrite=true \
        --output=/tmp/proftest/$1 \
        build_grpc/bench_grpc_server --port 5014$RANDOM_PORT --bufsize 1048576 \
        --n-buffers 200 --warmup 50 --out /tmp/proftest/$1.csv \
        --transport grpc --one-shot > /tmp/proftest/$1.log 2>&1 &
    local np=$!
    sleep 12
    kill -INT $np 2>/dev/null
    wait $np 2>/dev/null
    pkill -9 -f bench_grpc_server 2>/dev/null
    nsys export --type sqlite --force-overwrite=true \
        --output /tmp/proftest/$1.sqlite /tmp/proftest/$1.nsys-rep >/dev/null 2>&1
}

RANDOM_PORT=1
unset LD_LIBRARY_PATH
probe noldpath

RANDOM_PORT=2
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release"
probe withldpath

python3 - <<'PY'
import sqlite3
from collections import Counter
for tag in ("noldpath", "withldpath"):
    try:
        cx = sqlite3.connect("/tmp/proftest/%s.sqlite" % tag)
        T = {r[0] for r in cx.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        S = {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}
        c = Counter()
        for (nid,) in cx.execute("SELECT nameId FROM CUPTI_ACTIVITY_KIND_RUNTIME"):
            c[S.get(nid, "?")] += 1
        k = list(cx.execute("SELECT count(*) FROM CUPTI_ACTIVITY_KIND_KERNEL"))[0][0] \
            if 'CUPTI_ACTIVITY_KIND_KERNEL' in T else 0
        print("%-11s api=%-4d kernels=%-4d  %s"
              % (tag, sum(c.values()), k,
                 ", ".join("%s:%d" % kv for kv in c.most_common(4))))
    except Exception as e:
        print("%-11s cannot read: %s" % (tag, e))
PY
for t in noldpath withldpath; do
    printf "%-11s %s\n" "$t" "$(grep -a 'JIT' /tmp/proftest/$t.log)"
done
