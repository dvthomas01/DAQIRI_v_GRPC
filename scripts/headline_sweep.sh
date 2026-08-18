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

echo "arm,size,kb,rep,e2e_p50,e2e_p99,fft_p50,resid,n,result,gitsha" > "$OUT"

printf "%-6s %-9s %-6s %-4s %-9s %-9s %-9s %-8s %-6s %s\n" \
  "arm" "size" "KB" "rep" "e2e_p50" "e2e_p99" "fft_p50" "resid" "n" "result"
echo "--------------------------------------------------------------------------------------"

clean_all
for S in $SIZES; do
  KB=$(( S * 4 / 1024 ))
  for R in $(seq 1 "$REPS"); do
    for ARM in $ARMS; do
      LOG="/tmp/hl_${ARM}_${S}_${R}.log"
      CSV="data/hl_${ARM}_${S}_${R}.csv"
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

      if [ -n "${e2e50:-}" ] && [ -n "${fft50:-}" ]; then
        resid=$(awk -v a="$e2e50" -v b="$fft50" 'BEGIN{printf "%.2f", a-b}')
        res=OK
      else
        resid=NA; res=NORESULT
      fi

      printf "%-6s %-9s %-6s %-4s %-9s %-9s %-9s %-8s %-6s %s\n" \
        "$ARM" "$S" "$KB" "$R" "${e2e50:-NA}" "${e2e99:-NA}" "${fft50:-NA}" \
        "$resid" "${n:-NA}" "$res"
      echo "$ARM,$S,$KB,$R,${e2e50:-NA},${e2e99:-NA},${fft50:-NA},$resid,${n:-NA},$res,$GITSHA" >> "$OUT"
    done
  done
  echo "--------------------------------------------------------------------------------------"
done
clean_all
echo "DONE_HEADLINE_SWEEP -> $OUT"
