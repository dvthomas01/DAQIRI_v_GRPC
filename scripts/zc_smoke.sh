#!/usr/bin/env bash
# zc_smoke.sh — quick A/B check of the shmem copy vs --zero-copy path.
# Runs one shmem session each way and prints row count + p50 of the key metrics.
set -u
cd "$HOME/daqiri_gpu"

SERVER="build_grpc/bench_grpc_server"
CLIENT="build_grpc/bench_grpc_client"
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

BS=16384; N=500; W=50; PACE=400; PORT=50098

run_one () {
    local LABEL=$1 CSV=$2; shift 2
    local EXTRA=("$@")
    pkill -9 -f bench_grpc_server 2>/dev/null || true
    sleep 1
    rm -rf /tmp/iceoryx2 2>/dev/null || true
    rm -f /dev/shm/iox2_* 2>/dev/null || true
    rm -f "$CSV"
    sleep 1
    "$SERVER" --port "$PORT" --bufsize "$BS" --n-buffers "$N" --warmup "$W" \
              --out "$CSV" --transport shmem --one-shot "${EXTRA[@]}" \
              >"/tmp/zc_srv_${LABEL}.log" 2>&1 &
    local SPID=$!
    sleep 4
    "$CLIENT" --server "localhost:$PORT" --transport shmem \
              --bufsize "$BS" --n-buffers "$N" --warmup "$W" --pace-us "$PACE" \
              >"/tmp/zc_cli_${LABEL}.log" 2>&1
    wait $SPID 2>/dev/null || true
}

run_one copy     /tmp/zc_copy.csv     --verify
run_one zerocopy /tmp/zc_zerocopy.csv --zero-copy --verify
run_one zcparse  /tmp/zc_zcparse.csv  --zc-parse --verify

python3 - <<'PY'
import csv, statistics
def stats(path):
    try:
        rows = list(csv.DictReader(open(path)))
    except FileNotFoundError:
        return f"{path}: MISSING"
    n = len(rows)
    def p50(col):
        vals = [float(r[col]) for r in rows if col in r and r[col] not in ("", None)]
        vals = [v for v in vals if v > 0] if col == "wire_latency_us" else vals
        return statistics.median(vals) if vals else float("nan")
    return (f"{path}\n"
            f"  rows={n}  transfer_p50={p50('transfer_latency_us'):.2f}us  "
            f"wire_p50={p50('wire_latency_us'):.2f}us  e2e_p50={p50('e2e_latency_us'):.2f}us  "
            f"fft_p50={p50('fft_exec_us'):.2f}us")
print(stats('/tmp/zc_copy.csv'))
print(stats('/tmp/zc_zerocopy.csv'))
print(stats('/tmp/zc_zcparse.csv'))
PY

echo "--- correctness (detected peaks) ---"
grep -h "\[verify\]" /tmp/zc_srv_copy.log /tmp/zc_srv_zerocopy.log /tmp/zc_srv_zcparse.log
echo "--- server tail (zcparse / Level 2) ---"
grep -E "session opened|Transport mode|zero-copy|L2|CUDA|PASSED|no measured" /tmp/zc_srv_zcparse.log | head -20
echo "ZC_SMOKE_DONE"
