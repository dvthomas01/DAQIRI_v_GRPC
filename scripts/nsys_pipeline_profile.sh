#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Nsight Systems stage profile: where does the time go in each pipeline?
# ---------------------------------------------------------------------------
# WHY THIS SHAPE
#
# The question is not "how fast is each arm" -- headline_sweep.sh already
# answers that and its numbers are the ones we quote. The question is which
# PART of each pipeline the difference lives in. So this script trades
# statistical weight for structure: fewer messages, but a full CUDA and syscall
# timeline for every one of them.
#
# Three design decisions worth stating, because each one was a way to get a
# wrong answer:
#
# 1. EVERY PROFILED RUN IS PAIRED WITH AN UNPROFILED CONTROL of the same arm,
#    same size, same rep, run adjacently. nsys intercepts every CUDA call and
#    every syscall over the threshold, so it inflates absolute times. Without
#    the control we would not know by how much, and a profile that shifts the
#    arms by different amounts would silently reorder them. The control is what
#    licenses reading the decomposition at all.
#
# 2. ncu IS NOT USED, because it cannot be. /proc/driver/nvidia/params reports
#    RmProfilingAdminOnly: 1 and there is no passwordless sudo on this box, so
#    ncu dies with ERR_NVGPUCTRPERM. That means NO hardware counters: no DRAM
#    throughput, no L2 hit rate, no memory-stall breakdown. We can see how long
#    each cuFFT kernel runs and we cannot see why. Stated here so nobody reads
#    the absence of a memory analysis as a decision.
#
# 3. ARMS ROTATE WITHIN EACH REP, same as headline_sweep.sh. The GB10 cannot
#    have its clocks locked, so fixed arm order confounds position with arm.
#
# osrt-threshold keeps syscalls shorter than 1 us out of the trace. The
# blocking calls we care about (poll, futex, ioctl on the driver fd) are all
# far longer than that, and tracing every short call is most of nsys overhead.
# ---------------------------------------------------------------------------
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
DAQ=./build/daqiri/bench_daqiri_roce_pipeline
YAML=daqiri/config_roce_pipeline.yaml
EXSRV="${EXSRV:-/tmp/extbuf_fft_server}"
EXCLI="${EXCLI:-/tmp/extbuf_fft_client}"
RDMA_IP="${RDMA_IP:-192.168.20.1}"
EXPORT_="${EXPORT_:-18841}"
EXSLOTS="${EXSLOTS:-4}"

SIZES="${SIZES:-1048576 4096}"
ARMS="${ARMS:-base opt daq extbuf}"
REPS="${REPS:-3}"
N="${N:-200}"; W="${W:-50}"; PACE="${PACE:-25}"; PORT="${PORT:-50107}"
MIN_SM_MHZ="${MIN_SM_MHZ:-2400}"
PROFDIR="${PROFDIR:-/tmp/prof}"
OUT="${OUT:-data/nsys_overhead.csv}"
GITSHA="${GITSHA:-unknown}"

NSYS_ARGS="--trace=cuda,osrt --osrt-threshold=1000 --sample=none --cpuctxsw=none \
--cuda-memory-usage=false --force-overwrite=true"

mkdir -p "$PROFDIR" data
rm -f "$PROFDIR"/pp_*.nsys-rep "$PROFDIR"/pp_*.sqlite

for B in "$SERVER" "$CLIENT" "$DAQ" "$EXSRV" "$EXCLI"; do
    [ -x "$B" ] || { echo "ABORT: missing $B"; exit 1; }
done

clean_all () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
    pkill -9 -f extbuf_fft_server 2>/dev/null
    pkill -9 -f extbuf_fft_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

col_p50 () {
    tail -n +2 "$1" 2>/dev/null | cut -d, -f"$2" | grep -E '^[0-9.]+$' | sort -g \
      | awk -v p="$3" '{v[n++]=$1} END{ if(n) printf "%.3f", v[int(p*(n-1))] }'
}

CLK_PID=""
start_clock_sampler () {
    : > /tmp/pp_clk.txt
    ( while :; do
        nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null
        sleep 0.2
      done >> /tmp/pp_clk.txt ) &
    CLK_PID=$!
}
stop_clock_sampler () {
    [ -n "$CLK_PID" ] && kill "$CLK_PID" 2>/dev/null
    wait "$CLK_PID" 2>/dev/null
    CLK_PID=""
    tr -dc '0-9\n' < /tmp/pp_clk.txt | grep -E '^[0-9]+$' | sort -n | tail -1
}

# run_cell <arm> <size> <rep> <profile:0|1>
# Sets globals e2e50 fft50 nmsg. Writes a .nsys-rep when profiling.
run_cell () {
    local ARM=$1 S=$2 R=$3 PROF=$4
    local tag="${ARM}_${S}_${R}"
    local LOG="/tmp/pp_${tag}_p${PROF}.log"
    local CSV="$PROFDIR/pp_${tag}_p${PROF}.csv"
    local NS=""
    [ "$PROF" = "1" ] && NS="nsys profile $NSYS_ARGS --output=$PROFDIR/pp_${tag}"

    e2e50=""; fft50=""; nmsg=""
    clean_all
    rm -f "$CSV"

    if [ "$ARM" = "daq" ]; then
        timeout 300 $NS $DAQ --yaml $YAML --bufsize $S --n-buffers $N --warmup $W \
            --pace-us $PACE --zero-copy --out "$CSV" >"$LOG" 2>&1
        nmsg=$(grep -a 'RX rcvd' "$LOG" | grep -aoE '[0-9]+' | head -1)
        e2e50=$(awk '/E2E latency/{f=1} f&&/p50/{print $3; exit}' "$LOG")
        fft50=$(awk '/cuFFT execution/{f=1} f&&/p50/{print $3; exit}' "$LOG")
    elif [ "$ARM" = "extbuf" ]; then
        timeout 300 $NS $EXSRV --addr $RDMA_IP --port $EXPORT_ --npts $S \
            --warmup $W --msgs $N --slots $EXSLOTS --csv "$CSV" \
            --sha "$GITSHA" --verify off >"$LOG" 2>&1 &
        local SPID=$!
        sleep 3
        ( cd /tmp && GRPC_DIRECT_RDMA_LOCAL=$RDMA_IP timeout 200 $EXCLI \
            --host $RDMA_IP --port $EXPORT_ --npts $S --msgs $((W + N)) \
            --warmup $W --pace-us $PACE --linger-ms 400 --gen inplace \
            --csv /tmp/pp_extbuf_cli.csv ) >>"$LOG" 2>&1
        wait $SPID 2>/dev/null
        nmsg=$(tail -n +2 "$CSV" 2>/dev/null | wc -l)
        e2e50=$(col_p50 "$CSV" 5 0.50)
        fft50=$(col_p50 "$CSV" 6 0.50)
    else
        local FL
        case "$ARM" in
          base) FL="--zero-copy --no-zc-align --no-opt-stream" ;;
          opt)  FL="--zero-copy" ;;
        esac
        timeout 300 $NS $SERVER --port $PORT --bufsize $S --n-buffers $N --warmup $W \
            --out "$CSV" --transport shmem --one-shot $FL >"$LOG" 2>&1 &
        local SPID=$!
        sleep 5
        timeout 200 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
            --bufsize $S --n-buffers $N --warmup $W --pace-us $PACE >>"$LOG" 2>&1
        wait $SPID 2>/dev/null
        nmsg=$(grep -aoE 'n_measured=[0-9]+' "$LOG" | head -1 | cut -d= -f2)
        e2e50=$(awk '/E2E p50/{print $4; exit}' "$LOG")
        fft50=$(awk '/cuFFT p50/{print $4; exit}' "$LOG")
    fi
}

# ── warm the clocks on real load before any cell is recorded ────────────────
# Deliberately NOT tied to $N. A short validation run sets N small, and a
# warmup that inherited it would be too brief to ramp the part, so the gate
# would abort for a reason that has nothing to do with the machine.
WN=200; WW=50
echo "warmup: ramping GPU under load, target ${MIN_SM_MHZ} MHz"
ok=0
for r in 1 2 3 4 5 6 7 8; do
    clean_all
    start_clock_sampler
    timeout 200 $SERVER --port $PORT --bufsize 1048576 --n-buffers $WN --warmup $WW \
        --out /dev/null --transport shmem --one-shot --zero-copy >/dev/null 2>&1 &
    spid=$!
    sleep 5
    timeout 150 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize 1048576 --n-buffers $WN --warmup $WW --pace-us $PACE >/dev/null 2>&1
    wait $spid 2>/dev/null
    peak=$(stop_clock_sampler)
    echo "  round $r: peak ${peak:-?} MHz"
    if [ -n "$peak" ] && [ "$peak" -ge "$MIN_SM_MHZ" ]; then ok=1; break; fi
done
[ "$ok" = "1" ] || { echo "ABORT: GPU never reached ${MIN_SM_MHZ} MHz."; exit 1; }
echo

echo "arm,size,rep,profiled,e2e_p50,fft_p50,n,sm_mhz,pace_us,gitsha" > "$OUT"
printf "%-7s %-9s %-4s %-5s %-9s %-9s %-6s %s\n" arm size rep prof e2e_p50 fft_p50 n sm_mhz
echo "-------------------------------------------------------------------------"

NARMS=$(echo $ARMS | wc -w)
for S in $SIZES; do
  for R in $(seq 1 "$REPS"); do
    # rotate the starting arm each rep so position does not attach to identity
    ORDER=""
    i=0
    while [ $i -lt $NARMS ]; do
        idx=$(( (i + R - 1) % NARMS + 1 ))
        ORDER="$ORDER $(echo $ARMS | tr ' ' '\n' | sed -n "${idx}p")"
        i=$((i+1))
    done
    for ARM in $ORDER; do
      for PROF in 0 1; do
        start_clock_sampler
        run_cell "$ARM" "$S" "$R" "$PROF"
        SM=$(stop_clock_sampler)
        printf "%-7s %-9s %-4s %-5s %-9s %-9s %-6s %s\n" \
            "$ARM" "$S" "$R" "$PROF" "${e2e50:-NA}" "${fft50:-NA}" "${nmsg:-0}" "${SM:-?}"
        echo "$ARM,$S,$R,$PROF,${e2e50:-NA},${fft50:-NA},${nmsg:-0},${SM:-},$PACE,$GITSHA" >> "$OUT"
      done
    done
  done
done

clean_all
echo
echo "=== exporting sqlite from each report (needed for the stage query) ==="
for f in "$PROFDIR"/pp_*.nsys-rep; do
    [ -e "$f" ] || continue
    nsys export --type sqlite --force-overwrite=true --output "${f%.nsys-rep}.sqlite" "$f" >/dev/null 2>&1 \
        && echo "  ok   $(basename ${f%.nsys-rep})" \
        || echo "  FAIL $(basename ${f%.nsys-rep})"
done
echo
echo "reports in $PROFDIR:"
ls -1 "$PROFDIR"/pp_*.sqlite 2>/dev/null | wc -l
echo "overhead table: $OUT"
