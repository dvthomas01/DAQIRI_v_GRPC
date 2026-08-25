#!/usr/bin/env bash
# The server's whole session is invisible to CUPTI but its teardown is captured
# perfectly, and this happens on the plain gRPC path too, so it is a property of
# the bench_grpc_server binary rather than of the transport.
#
# Last discriminator: profile the server with NO client. The startup block does
# cudaMalloc x2, a cuFFT plan build and one execute, entirely on the main thread
# before any networking exists. If those calls appear, CUPTI works in this
# binary and something during the run silences it. If they do not appear, CUPTI
# never sees this binary's FFT path at all.
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
cd "$HOME/daqiri_gpu" || exit 1
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"
pkill -9 -f bench_grpc_server 2>/dev/null; sleep 1

nsys profile --trace=cuda --sample=none --cpuctxsw=none --force-overwrite=true \
    --output=/tmp/proftest/warmonly \
    build_grpc/bench_grpc_server --port 50139 --bufsize 1048576 --n-buffers 200 \
    --warmup 50 --out /tmp/proftest/warmonly.csv --transport grpc --one-shot \
    > /tmp/proftest/warmonly.log 2>&1 &
NP=$!
sleep 12
# SIGINT so nsys stops collection cleanly rather than losing the session
kill -INT $NP 2>/dev/null
wait $NP 2>/dev/null
pkill -9 -f bench_grpc_server 2>/dev/null

nsys export --type sqlite --force-overwrite=true \
    --output /tmp/proftest/warmonly.sqlite /tmp/proftest/warmonly.nsys-rep >/dev/null 2>&1

echo "=== did the warm-up itself get traced? ==="
python3 - <<'PY'
import sqlite3
from collections import Counter
cx = sqlite3.connect("/tmp/proftest/warmonly.sqlite")
T = {r[0] for r in cx.execute("SELECT name FROM sqlite_master WHERE type='table'")}
S = {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}
c = Counter()
for (nid,) in cx.execute("SELECT nameId FROM CUPTI_ACTIVITY_KIND_RUNTIME"):
    c[S.get(nid, "?")] += 1
k = list(cx.execute("SELECT count(*) FROM CUPTI_ACTIVITY_KIND_KERNEL"))[0][0] \
    if 'CUPTI_ACTIVITY_KIND_KERNEL' in T else 0
print("  api calls=%d  kernels=%d" % (sum(c.values()), k))
for nm, n in c.most_common(12):
    print("    %-38s %5d" % (nm, n))
PY
echo
grep -a 'JIT' /tmp/proftest/warmonly.log
