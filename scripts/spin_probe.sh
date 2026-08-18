#!/usr/bin/env bash
# SPIN-VS-BLOCK PROBE — does our own wait loop cause the cuFFT gap?
#
# ---------------------------------------------------------------------------
# WHY THIS RUN EXISTS
# ---------------------------------------------------------------------------
# Two independent experiments have now failed to explain why our cuFFT is
# slower than DAQiri's: --zc-bigreg (registration granularity) came back
# 9/15, p = 0.61, and the standalone placement ladder found every host memory
# kind identical (shmreg 53.66 vs hostalloc 53.66 us at 4 MB, 45 cells, p = 1).
#
# The ladder did produce one strong clue, by accident.  It built its executor
# with the default constructor, which BLOCKS on cudaEventSynchronize, and it
# ran outside any pipeline.  Lining its numbers up against the pipeline's at
# 4 MB:
#
#     our memory kind   isolated 53.66   in pipeline 63.76   tax +10.10
#     DAQiri's kind     isolated 53.66   in pipeline 57.36   tax  +3.70
#
# Identical in isolation; the whole 6.40 us gap is created by the surroundings.
# The largest difference in the surroundings is how each arm waits for the GPU:
#
#     ours    cudaEventQuery in a bare unthrottled loop  (--opt-stream)
#     DAQiri  cudaEventSynchronize, parks the thread
#
# On a coherent C2C part the FFT streams its input over the same link the
# polling thread is hammering.  A longer transform means more polling during
# it, and transform time scales with payload, so contention would scale with
# payload too.  That is the per-byte signature we assumed had to be placement.
#
# ---------------------------------------------------------------------------
# WHY THIS ARM HAS NEVER BEEN RUN BEFORE
# ---------------------------------------------------------------------------
# The headline sweep's `base` arm is `--no-zc-align --no-opt-stream`: it turns
# OFF spinning and OFF the copy elimination at the same time, so it can never
# separate them.  `optblock` below changes exactly one variable against
# `optspin`: it keeps the in-place FFT and only swaps the wait.  That is the
# whole point of the run.
#
# ---------------------------------------------------------------------------
# PREDICTION, RECORDED BEFORE THE DATA EXISTS
# ---------------------------------------------------------------------------
#   * optblock fft < optspin fft at 1 MB and above, difference growing w/ size
#   * optblock e2e slightly WORSE at 16-64 KB, where the ~1 us wakeup dominates
#   * if both hold, the fix is a size-adaptive wait (spin small, block large)
# A flat difference at all sizes would mean something other than contention.
# No difference exonerates the wait and closes this line of investigation.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
DAQ=./build/daqiri/bench_daqiri_roce_pipeline
YAML=daqiri/config_roce_pipeline.yaml

# Six sizes: the small end is where blocking should LOSE, the large end is
# where it should win.  A crossover is the outcome we are trying to locate,
# and you cannot locate a crossover from one side of it.
SIZES="${SIZES:-4096 16384 65536 262144 524288 1048576}"
ARMS="${ARMS:-optspin optblock daq}"
REPS="${REPS:-3}"
N=200; W=50; PACE=400; PORT=50106
OUT="${OUT:-data/spin_runs.csv}"

SRC=grpc_direct/bench_grpc_server.cc
if [ ! -x "$SERVER" ]; then echo "ABORT: $SERVER not built."; exit 1; fi
if [ "$SRC" -nt "$SERVER" ]; then
    echo "ABORT: $SRC is newer than $SERVER.  Rebuild first."; exit 1
fi
if ! grep -qa -- '--no-opt-stream' "$SERVER"; then
    echo "ABORT: $SERVER has no --no-opt-stream flag; wrong or stale binary."; exit 1
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
        optspin)  echo "--zero-copy" ;;                   # spins (default)
        optblock) echo "--zero-copy --no-opt-stream" ;;    # blocks, same FFT path
    esac
}

run_grpc () {   # $1=arm $2=size $3=log $4=csv $5=extra
    timeout 120 $SERVER --port $PORT --bufsize "$2" --n-buffers $N --warmup $W \
        --out "$4" --transport shmem --one-shot $(arm_flags "$1") $5 >"$3" 2>&1 &
    local sp=$!
    sleep 4
    timeout 100 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize "$2" --n-buffers $N --warmup $W --pace-us $PACE >>"$3" 2>&1
    wait $sp 2>/dev/null
}

# ── correctness first ────────────────────────────────────────────────────────
# Changing how we WAIT must not change the answer.  If it does, something is
# being read before it is finished and every number below is fiction.
echo "=== CORRECTNESS: top-3 spectral peaks, optspin vs optblock ==="
clean_all
for S in 4096 65536 1048576; do
    KB=$(( S * 4 / 1024 ))
    for ARM in optspin optblock; do
        L="/tmp/sv_${ARM}_${S}.log"
        clean_all
        run_grpc "$ARM" "$S" "$L" "/tmp/sv_${ARM}_${S}.csv" "--verify"
        PK=$(grep -a 'top-3 peaks' "$L" | head -1 | sed 's/.*: //')
        printf "  %-9s %6s KB   %s\n" "$ARM" "$KB" "${PK:-NO PEAKS REPORTED}"
    done
done
echo

# ── timing ───────────────────────────────────────────────────────────────────
echo "build: $GITSHA"
echo "spin probe: ${REPS} reps x $(echo $ARMS | wc -w) arms x $(echo $SIZES | wc -w) sizes, interleaved"
echo
echo "arm,size,kb,rep,e2e_p50,e2e_p99,fft_p50,resid,n,result,gitsha" > "$OUT"
printf "%-9s %-9s %-6s %-4s %-9s %-9s %-9s %-8s %-6s %s\n" \
  "arm" "size" "KB" "rep" "e2e_p50" "e2e_p99" "fft_p50" "resid" "n" "result"
echo "---------------------------------------------------------------------------------------"

clean_all
for S in $SIZES; do
  KB=$(( S * 4 / 1024 ))
  for R in $(seq 1 "$REPS"); do
    for ARM in $ARMS; do
      LOG="/tmp/sp_${ARM}_${S}_${R}.log"
      CSV="data/sp_${ARM}_${S}_${R}.csv"
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
        # Both gRPC arms must take the in-place route.  If optblock somehow
        # fell into the realign copy, it would be a different experiment.
        # The server prints the enum through FeedModeName(), which spells it
        # "in-place (no copy)" -- matching on the C++ enum name finds nothing
        # and produces a warning on every run, which is worse than no guard.
        if ! grep -qa 'in-place (no copy)' "$LOG"; then
            echo "    WARNING: $ARM at $S did not report the in-place FFT route"
        fi
      fi

      if [ -n "${e2e50:-}" ] && [ -n "${fft50:-}" ]; then
        resid=$(awk -v a="$e2e50" -v b="$fft50" 'BEGIN{printf "%.2f", a-b}')
        res=OK
      else
        resid=NA; res=NORESULT
      fi

      printf "%-9s %-9s %-6s %-4s %-9s %-9s %-9s %-8s %-6s %s\n" \
        "$ARM" "$S" "$KB" "$R" "${e2e50:-NA}" "${e2e99:-NA}" "${fft50:-NA}" \
        "$resid" "${n:-NA}" "$res"
      echo "$ARM,$S,$KB,$R,${e2e50:-NA},${e2e99:-NA},${fft50:-NA},$resid,${n:-NA},$res,$GITSHA" >> "$OUT"
    done
  done
  echo "---------------------------------------------------------------------------------------"
done
clean_all
echo "DONE_SPIN_PROBE -> $OUT"
echo "analyze: python3 scripts/headline_table.py $OUT --arms optspin,optblock,daq"
