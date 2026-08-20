#!/usr/bin/env bash
# HEADLINE ARTIFACT — gRPC-Direct before/after vs DAQiri RoCE, 9 sizes.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS IN THIS SHAPE
# ---------------------------------------------------------------------------
# The earlier version of this comparison ran scripts/grpc_sweep.sh (27 runs) and
# THEN scripts/roce_sweep.sh (18 runs).  Back to back, not interleaved.  GPU
# clocks cannot be locked on this box, and that separation alone manufactured a
# reported 12.2 us gap at 4 MB that a properly paired run showed to be 2.9 us.
# The arms drifted apart thermally, and the drift got read as a result.
#
# So: at every size we run base -> opt -> daq ADJACENTLY, then repeat that
# triple REPS times.  Any clock wander now hits all three arms nearly equally
# and largely cancels in the paired differences.
#
# Three arms:
#   base : gRPC zero-copy, pre-optimization  (--no-zc-align --no-opt-stream)
#   opt  : gRPC current defaults             (alignment probe + dedicated stream)
#   daq  : DAQiri RoCE zero-copy             (the target we are chasing)
#
# We record e2e p50/p99 AND cuFFT p50, because the derived residual
# (e2e_p50 - fft_p50) is the only quantity that is stable under clock drift.
# e2e moves when the GPU clock moves; the residual does not, because the
# transform time moves with it.  Report both, trust the residual.
#
# Emits data/headline_runs.csv (one row per run) for scripts/headline_table.py.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
DAQ=./build/daqiri/bench_daqiri_roce_pipeline
YAML=daqiri/config_roce_pipeline.yaml

SIZES="${SIZES:-4096 8192 16384 32768 65536 131072 262144 524288 1048576}"
ARMS="${ARMS:-base opt daq}"
REPS="${REPS:-2}"
N=200; W=50; PACE=400; PORT=50104
# ── GPU clock gate ──────────────────────────────────────────────────────────
# The GB10 parks at idle clocks and only ramps under sustained load, and this
# was nearly read as a transport result: a run taken minutes after a reboot
# reported cuFFT p50 21.25 us and e2e 38.61 us, the next run 7.62 and 12.66,
# with nothing changed. clocks.sm was 208 MHz against a 3003 MHz maximum.
#
# This lives in the script rather than in LONGTERM_CONTEXT.md on purpose. A
# rule in a document is followed by whoever read the document. A gate in the
# harness is followed by everyone.
#
# Two mechanisms, and they do different jobs. The warmup removes the
# systematic part: without it the first arm of every session eats the idle
# penalty and the bias attaches to position rather than scattering as noise.
# The gate catches the rest, including a mid-sweep downclock from thermals.
MIN_SM_MHZ="${MIN_SM_MHZ:-2400}"
WARMUP_ROUNDS="${WARMUP_ROUNDS:-8}"
WARMUP_SIZE="${WARMUP_SIZE:-1048576}"
# Overridable so a smoke test can be sent somewhere harmless.  This file is
# truncated on start, so pointing a short validation run at the real path would
# leave a stub that looks like the headline artifact if the full run then died.
OUT="${OUT:-data/headline_runs.csv}"

# ── build-freshness guard ────────────────────────────────────────────────────
# An scp once died before the rebuild, leaving this box with a binary that did
# not contain the change being measured.  The sweep would have produced clean,
# publishable, wrong numbers.  Refuse to run in that state.
SRC=grpc_direct/bench_grpc_server.cc
if [ ! -x "$SERVER" ]; then
    echo "ABORT: $SERVER not built."; exit 1
fi
if [ "$SRC" -nt "$SERVER" ]; then
    echo "ABORT: $SRC is newer than $SERVER.  Rebuild first:"
    echo "  cmake --build ~/daqiri_gpu/build_grpc --parallel 16 --target bench_grpc_server"
    exit 1
fi
# Direct check that the binary actually contains the current flag set, which
# catches a stale binary whose mtime happens to look fine.
if ! grep -qa -- '--no-opt-stream' "$SERVER"; then
    echo "ABORT: $SERVER predates the --opt-stream work (flag string absent)."
    echo "  scp the source and rebuild before sweeping."
    exit 1
fi

# The tree on the Spark is an scp mirror, not a clone, so there is usually no
# git metadata here to read.  Pass the workstation's SHA in explicitly:
#     GITSHA=952b68a bash scripts/headline_sweep.sh
# Stamping "unknown" would leave the headline CSV unattributable to any commit,
# which defeats the point, so if no SHA is supplied we fall back to a hash of
# the source that was actually compiled on this box.  That is weaker than a
# commit id but it still pins the rows to specific bytes.
if [ -z "${GITSHA:-}" ]; then
    GITSHA=$(git -C "$HOME/daqiri_gpu" rev-parse --short HEAD 2>/dev/null || true)
    DIRTY=$(git -C "$HOME/daqiri_gpu" status --porcelain -- "$SRC" 2>/dev/null | head -c1)
    [ -n "$GITSHA" ] && [ -n "$DIRTY" ] && GITSHA="${GITSHA}+dirty"
fi
[ -z "${GITSHA:-}" ] && GITSHA="srchash:$(sha256sum "$SRC" | cut -c1-10)"
echo "build: $GITSHA   server mtime: $(date -r "$SERVER" '+%Y-%m-%d %H:%M:%S')"
echo "sweep: ${REPS} reps x $(echo $ARMS | wc -w) arms x $(echo $SIZES | wc -w) sizes, arms interleaved"
echo

clean_all () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

# The clock has to be sampled DURING the run, not before or after it.
# Measured on this box: 208 208 208 2405 2405 2405 2405 2457 2405 234 208 208,
# one sample per second across a single cell. It ramps about three seconds
# into sustained load and falls back to idle within one second of the load
# stopping. So a reading taken between runs reports 208 every time and says
# nothing about the conditions the numbers were produced under.
#
# The peak is the statistic, not the mean. The window includes the four second
# wait between server start and client start, which is idle by construction,
# and averaging that in would drag every cell under the threshold for a reason
# that has nothing to do with the measurement.
CLK_PID=""
start_clock_sampler () {
    : > /tmp/hl_clk.txt
    ( while :; do
        nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null
        sleep 0.2
      done >> /tmp/hl_clk.txt ) &
    CLK_PID=$!
}
stop_clock_sampler () {
    [ -n "$CLK_PID" ] && kill "$CLK_PID" 2>/dev/null
    wait "$CLK_PID" 2>/dev/null
    CLK_PID=""
    tr -dc '0-9\n' < /tmp/hl_clk.txt | grep -E '^[0-9]+$' | sort -n | tail -1
}

# Drive real load until the clocks come up. The base arm is used as the burn
# rather than a synthetic kernel so that the warmup exercises the same code the
# sweep measures, which also shakes out a broken build before any row is
# written instead of after the first arm.
#
# This cannot leave the GPU clocked up, because nothing can: the clock decays
# within a second of the load ending. What it does is confirm the part ramps at
# all under this workload, and pay the first-touch costs, CUDA context creation
# and cuFFT plan setup, before any row is recorded rather than inside the first
# arm of the sweep. Without it that cost lands entirely on whichever arm runs
# first and becomes a bias attached to position.
warm_clocks () {
    local r peak
    echo "warmup: ramping under load, target ${MIN_SM_MHZ} MHz"
    for r in $(seq 1 "$WARMUP_ROUNDS"); do
        clean_all
        start_clock_sampler
        timeout 120 $SERVER --port $PORT --bufsize "$WARMUP_SIZE" --n-buffers $N \
            --warmup $W --out /dev/null --transport shmem --one-shot \
            --zero-copy >/dev/null 2>&1 &
        local spid=$!
        sleep 4
        timeout 100 taskset -c 11 $CLIENT --server "localhost:$PORT" \
            --transport shmem --bufsize "$WARMUP_SIZE" --n-buffers $N \
            --warmup $W --pace-us $PACE >/dev/null 2>&1
        wait $spid 2>/dev/null
        peak=$(stop_clock_sampler)
        echo "warmup round $r: peak ${peak:-?} MHz"
        if [ -n "$peak" ] && [ "$peak" -ge "$MIN_SM_MHZ" ]; then
            return 0
        fi
    done
    return 1
}

echo "arm,size,kb,rep,e2e_p50,e2e_p99,fft_p50,resid,n,result,gitsha,sm_mhz" > "$OUT"

printf "%-6s %-9s %-6s %-4s %-9s %-9s %-9s %-8s %-6s %-7s %s\n" \
  "arm" "size" "KB" "rep" "e2e_p50" "e2e_p99" "fft_p50" "resid" "n" "sm_mhz" "result"
echo "--------------------------------------------------------------------------------------"

clean_all
if ! warm_clocks; then
    echo "ABORT: GPU never reached ${MIN_SM_MHZ} MHz. Every row would be gated out,"
    echo "  so there is nothing to collect. Check load and thermals, or lower"
    echo "  MIN_SM_MHZ deliberately and record that you did."
    exit 1
fi
echo
for S in $SIZES; do
  KB=$(( S * 4 / 1024 ))
  for R in $(seq 1 "$REPS"); do
    for ARM in $ARMS; do
      LOG="/tmp/hl_${ARM}_${S}_${R}.log"
      CSV="data/hl_${ARM}_${S}_${R}.csv"
      clean_all
      rm -f "$CSV"
      start_clock_sampler

      if [ "$ARM" = "daq" ]; then
        timeout 90 $DAQ --yaml $YAML --bufsize $S --n-buffers $N --warmup $W \
            --pace-us $PACE --zero-copy --out "$CSV" >"$LOG" 2>&1
        n=$(grep -a 'RX rcvd' "$LOG" | grep -aoE '[0-9]+' | head -1)
        e2e50=$(awk '/E2E latency/{f=1} f&&/p50/{print $3; exit}' "$LOG")
        e2e99=$(awk '/E2E latency/{f=1} f&&/p99/{print $3; exit}' "$LOG")
        fft50=$(awk '/cuFFT execution/{f=1} f&&/p50/{print $3; exit}' "$LOG")
      else
        case "$ARM" in
          base) FL="--zero-copy --no-zc-align --no-opt-stream" ;;
          opt)  FL="--zero-copy" ;;
        esac
        timeout 120 $SERVER --port $PORT --bufsize $S --n-buffers $N --warmup $W \
            --out "$CSV" --transport shmem --one-shot $FL >"$LOG" 2>&1 &
        SPID=$!
        sleep 4
        timeout 100 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
            --bufsize $S --n-buffers $N --warmup $W --pace-us $PACE >>"$LOG" 2>&1
        wait $SPID 2>/dev/null
        n=$(grep -aoE 'n_measured=[0-9]+' "$LOG" | head -1 | cut -d= -f2)
        e2e50=$(awk '/E2E p50/{print $4; exit}' "$LOG")
        e2e99=$(awk '/E2E p50/{print $8; exit}' "$LOG")
        fft50=$(awk '/cuFFT p50/{print $4; exit}' "$LOG")
      fi

      SM=$(stop_clock_sampler)

      if [ -n "${e2e50:-}" ] && [ -n "${fft50:-}" ]; then
        resid=$(awk -v a="$e2e50" -v b="$fft50" 'BEGIN{printf "%.2f", a-b}')
        res=OK
      else
        resid=NA; res=NORESULT
      fi

      # A row taken below the threshold is written out and marked, never
      # silently dropped. headline_table.py keeps only result==OK, so the row
      # is excluded from the analysis while still appearing in the artifact as
      # evidence that the cell was attempted and why it does not count.
      # Silently missing cells read as an oversight.
      if [ -z "${SM:-}" ]; then
        res=NOCLOCK
      elif [ "$SM" -lt "$MIN_SM_MHZ" ]; then
        res=CLOCKLOW
      fi

      printf "%-6s %-9s %-6s %-4s %-9s %-9s %-9s %-8s %-6s %-7s %s\n" \
        "$ARM" "$S" "$KB" "$R" "${e2e50:-NA}" "${e2e99:-NA}" "${fft50:-NA}" \
        "$resid" "${n:-NA}" "${SM:-NA}" "$res"
      echo "$ARM,$S,$KB,$R,${e2e50:-NA},${e2e99:-NA},${fft50:-NA},$resid,${n:-NA},$res,$GITSHA,${SM:-NA}" >> "$OUT"

      # A cell that came in under the threshold means the box cooled off or
      # something else took the GPU. Re-ramp before the next cell rather than
      # letting one slow patch contaminate a run of them.
      if [ "$res" = CLOCKLOW ]; then
        echo "  clock gate: ${SM} MHz < ${MIN_SM_MHZ}, row excluded; re-ramping"
        warm_clocks || true
      fi
    done
  done
  echo "--------------------------------------------------------------------------------------"
done
clean_all
echo "DONE_HEADLINE_SWEEP -> $OUT"
