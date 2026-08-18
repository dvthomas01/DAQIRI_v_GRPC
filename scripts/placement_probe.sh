#!/usr/bin/env bash
# REGISTRATION-GRANULARITY PROBE (E4 re-measurement)
#
# ---------------------------------------------------------------------------
# WHY THIS RUN EXISTS
# ---------------------------------------------------------------------------
# The 2-rep headline sweep established, within paired (size, rep) cells, that
# gRPC's cuFFT is slower than DAQiri's in 18/18 cells (p = 7.6e-06) and that the
# difference grows with payload: 0.77 us at 16 KB to 6.40 us at 4 MB.  A code
# read confirmed both arms run the SAME plan (cufftPlan1d, CUFFT_R2C, batch 1,
# out-of-place, no work area), the SAME warmup, and write output to the SAME
# kind of memory (cudaMalloc'd device).  The one thing that differs is where the
# transform READS FROM:
#
#     gRPC : a loaned iceoryx2 shmem slot, cudaHostRegister'd over the EXACT
#            payload span, then mapped to a device pointer.
#     DAQiri: an RDMA host_pinned MR, whose slots are rounded up to the 64 KB
#            GPU page size.
#
# --zc-bigreg (E4) already exists to test exactly this: it rounds the
# registration down to a 64 KB boundary and up to a 64 KB multiple, so we
# register whole GPU pages the way DAQiri does, over the very same host memory.
# Nothing about the data or the plan changes; only the mapping granularity.
#
# E4 was measured once before and rejected.  That measurement predates the
# discovery that arms must be interleaved and repeated, and it was taken while
# we believed the cuFFT gap was 0.7 us of noise.  It is worth exactly one
# careful re-run now that the gap is known to be real and per-byte.
#
# NOTE: cudaHostRegisterReadOnly was tried previously and the GB10 driver
# rejects it outright ("operation not supported"), so it is not an arm here.
#
# ---------------------------------------------------------------------------
# WHAT WOULD COUNT AS AN ANSWER
# ---------------------------------------------------------------------------
# If mapping granularity is the mechanism, bigreg's fft_p50 should fall toward
# DAQiri's AND the improvement should GROW WITH SIZE, because a per-byte cost is
# the signature we are chasing.  A flat improvement of a fixed microsecond would
# instead point at per-registration overhead, which is a different animal.
# If bigreg changes nothing, mapping granularity is exonerated and the remaining
# suspects are the underlying page size of the iceoryx2 arena and NUMA/physical
# placement, neither of which we can reach from this side of the FFI boundary.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
DAQ=./build/daqiri/bench_daqiri_roce_pipeline
YAML=daqiri/config_roce_pipeline.yaml

# Five sizes spanning the range, because the claim under test is a SLOPE, not a
# single number.  One size cannot distinguish a per-byte cost from a fixed one.
SIZES="${SIZES:-4096 65536 262144 524288 1048576}"
ARMS="${ARMS:-exact bigreg daq}"
REPS="${REPS:-3}"
N=200; W=50; PACE=400; PORT=50105
OUT="${OUT:-data/placement_runs.csv}"

SRC=grpc_direct/bench_grpc_server.cc
if [ ! -x "$SERVER" ]; then echo "ABORT: $SERVER not built."; exit 1; fi
if [ "$SRC" -nt "$SERVER" ]; then
    echo "ABORT: $SRC is newer than $SERVER.  Rebuild first:"
    echo "  cmake --build ~/daqiri_gpu/build_grpc --parallel 16 --target bench_grpc_server"
    exit 1
fi
if ! grep -qa -- '--zc-bigreg' "$SERVER"; then
    echo "ABORT: $SERVER has no --zc-bigreg flag; wrong or stale binary."; exit 1
fi

if [ -z "${GITSHA:-}" ]; then
    GITSHA=$(git -C "$HOME/daqiri_gpu" rev-parse --short HEAD 2>/dev/null || true)
fi
[ -z "${GITSHA:-}" ] && GITSHA="srchash:$(sha256sum "$SRC" | cut -c1-10)"

clean_all () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

arm_flags () {
    case "$1" in
        exact)  echo "--zero-copy" ;;
        bigreg) echo "--zero-copy --zc-bigreg" ;;
    esac
}

run_grpc () {   # $1=arm  $2=size  $3=logfile  $4=csv  $5=extra flags
    timeout 120 $SERVER --port $PORT --bufsize "$2" --n-buffers $N --warmup $W \
        --out "$4" --transport shmem --one-shot $(arm_flags "$1") $5 >"$3" 2>&1 &
    local sp=$!
    sleep 4
    timeout 100 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize "$2" --n-buffers $N --warmup $W --pace-us $PACE >>"$3" 2>&1
    wait $sp 2>/dev/null
}

# ── correctness first: timing of a wrong answer is worthless ─────────────────
echo "=== CORRECTNESS: top-3 spectral peaks, exact vs bigreg ==="
echo "(identical peaks required before any timing below is believed)"
clean_all
for S in 4096 65536 1048576; do
    KB=$(( S * 4 / 1024 ))
    for ARM in exact bigreg; do
        L="/tmp/pv_${ARM}_${S}.log"
        clean_all
        run_grpc "$ARM" "$S" "$L" "/tmp/pv_${ARM}_${S}.csv" "--verify"
        PK=$(grep -a 'top-3 peaks' "$L" | head -1 | sed 's/.*: //')
        printf "  %-7s %6s KB   %s\n" "$ARM" "$KB" "${PK:-NO PEAKS REPORTED}"
    done
done
echo

# ── timing ───────────────────────────────────────────────────────────────────
echo "build: $GITSHA"
echo "probe: ${REPS} reps x $(echo $ARMS | wc -w) arms x $(echo $SIZES | wc -w) sizes, arms interleaved"
echo
echo "arm,size,kb,rep,e2e_p50,e2e_p99,fft_p50,resid,n,result,gitsha" > "$OUT"
printf "%-7s %-9s %-6s %-4s %-9s %-9s %-9s %-8s %-6s %s\n" \
  "arm" "size" "KB" "rep" "e2e_p50" "e2e_p99" "fft_p50" "resid" "n" "result"
echo "---------------------------------------------------------------------------------------"

clean_all
for S in $SIZES; do
  KB=$(( S * 4 / 1024 ))
  for R in $(seq 1 "$REPS"); do
    for ARM in $ARMS; do
      LOG="/tmp/pl_${ARM}_${S}_${R}.log"
      CSV="data/pl_${ARM}_${S}_${R}.csv"
      clean_all
      rm -f "$CSV"

      if [ "$ARM" = "daq" ]; then
        timeout 90 $DAQ --yaml $YAML --bufsize $S --n-buffers $N --warmup $W \
            --pace-us $PACE --zero-copy --out "$CSV" >"$LOG" 2>&1
        n=$(grep -a 'RX rcvd' "$LOG" | grep -aoE '[0-9]+' | head -1)
        e2e50=$(awk '/E2E latency/{f=1} f&&/p50/{print $3; exit}' "$LOG")
        e2e99=$(awk '/E2E latency/{f=1} f&&/p99/{print $3; exit}' "$LOG")
        fft50=$(awk '/cuFFT execution/{f=1} f&&/p50/{print $3; exit}' "$LOG")
      else
        run_grpc "$ARM" "$S" "$LOG" "$CSV" ""
        n=$(grep -aoE 'n_measured=[0-9]+' "$LOG" | head -1 | cut -d= -f2)
        e2e50=$(awk '/E2E p50/{print $4; exit}' "$LOG")
        e2e99=$(awk '/E2E p50/{print $8; exit}' "$LOG")
        fft50=$(awk '/cuFFT p50/{print $4; exit}' "$LOG")
        # A silent fallback to exact-span registration would make bigreg a
        # duplicate of exact and the comparison meaningless, so surface it.
        if [ "$ARM" = "bigreg" ] && grep -qa 'fell back to' "$LOG"; then
            echo "    WARNING: bigreg fell back to exact-span registration at $S"
        fi
      fi

      if [ -n "${e2e50:-}" ] && [ -n "${fft50:-}" ]; then
        resid=$(awk -v a="$e2e50" -v b="$fft50" 'BEGIN{printf "%.2f", a-b}')
        res=OK
      else
        resid=NA; res=NORESULT
      fi

      printf "%-7s %-9s %-6s %-4s %-9s %-9s %-9s %-8s %-6s %s\n" \
        "$ARM" "$S" "$KB" "$R" "${e2e50:-NA}" "${e2e99:-NA}" "${fft50:-NA}" \
        "$resid" "${n:-NA}" "$res"
      echo "$ARM,$S,$KB,$R,${e2e50:-NA},${e2e99:-NA},${fft50:-NA},$resid,${n:-NA},$res,$GITSHA" >> "$OUT"
    done
  done
  echo "---------------------------------------------------------------------------------------"
done
clean_all
echo "DONE_PLACEMENT_PROBE -> $OUT"
echo "analyze: python3 scripts/headline_table.py $OUT --arms exact,bigreg,daq"
