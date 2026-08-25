#!/usr/bin/env bash
# Per-stage decomposition of all four arms using ONE instrument.
#
# Why this exists. nsys gives a clean decomposition of the DAQiri binary and
# collects nothing usable from bench_grpc_server (CUPTI records one call at
# startup, nothing for the whole session, then the teardown; ruled out: child
# processes, trace volume, run length, flush interval, LD_LIBRARY_PATH,
# transport, profiler-API calls, static linkage). ncu is unavailable entirely
# because RmProfilingAdminOnly is 1 and there is no sudo. So the cross-arm
# comparison cannot be built out of nsys.
#
# What it does instead: both binaries now carry the SAME three stage timers,
# taken with the same clock at the same points relative to fft.execute(), and
# both report e2e over the same window (buffer in hand -> post-FFT). That makes
# the arms comparable to each other, which is what the question needs. nsys
# stays as an independent cross-check on the one arm it can see.
#
# Decomposition per message, all within the e2e window:
#   register+lookup   device-pointer cache lookup, plus cudaHostRegister on a miss
#   realign enqueue   the D2D realign copy, when the feed mode uses one
#   fft call (wall)   wall time of fft.execute()
#   fft_exec          the cuFFT kernel itself, from CUDA events (CSV column 3)
#   launch+sync       fft call (wall) minus fft_exec
#   residual          e2e minus the three stage timers
#
# Defaults reproduce Table B conditions (N=1000, W=500, PACE=25), because the
# 25.17 us extbuf penalty is present there and mostly absent at N=200.
set -u
cd "$HOME/daqiri_gpu" || exit 1

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
DAQ=build/daqiri/bench_daqiri_roce_pipeline
EXSRV=/tmp/extbuf_fft_server
EXCLI=/tmp/extbuf_fft_client
RDMA_IP=192.168.20.1

SIZES="${SIZES:-1048576 4096}"
ARMS="${ARMS:-base opt daq extbuf}"
REPS="${REPS:-3}"
N="${N:-1000}"; W="${W:-500}"; PACE="${PACE:-25}"; PORT="${PORT:-50161}"
OUT="${OUT:-data/stage_runs.csv}"
LOGDIR="${LOGDIR:-/tmp/stage}"
GITSHA="${GITSHA:-unknown}"
MIN_SM_MHZ="${MIN_SM_MHZ:-2400}"
mkdir -p "$LOGDIR" data

# The DAQiri stage timers are new, so refuse to run against a binary that
# predates them. A stale binary here would produce clean, publishable, wrong
# numbers, which is exactly the failure this guard exists for.
if ! grep -qa -- '--stage-timing' "$DAQ"; then
    echo "ABORT: $DAQ has no --stage-timing. Rebuild:"
    echo "  cmake --build ~/daqiri_gpu/build --parallel 16 --target bench_daqiri_roce_pipeline"
    exit 1
fi
grep -qa -- '--stage-timing' "$SERVER" || { echo "ABORT: $SERVER has no --stage-timing."; exit 1; }

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
      | awk '{v[n++]=$1} END{ if(n) printf "%.3f", v[int(0.5*(n-1))] }'
}

# The GB10 parks at idle clocks and ramps about three seconds into sustained
# load, so the clock has to be sampled DURING the cell. A reading taken between
# runs reports 208 MHz every time and says nothing about the conditions.
CLK_PID=""
start_clock_sampler () {
    : > /tmp/st_clk.txt
    ( while :; do
        nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null
        sleep 0.2
      done >> /tmp/st_clk.txt ) &
    CLK_PID=$!
}
stop_clock_sampler () {
    [ -n "$CLK_PID" ] && kill "$CLK_PID" 2>/dev/null
    wait "$CLK_PID" 2>/dev/null
    CLK_PID=""
    tr -dc '0-9\n' < /tmp/st_clk.txt | grep -E '^[0-9]+$' | sort -n | tail -1
}

# "  <name> p50/p99 : 1.234 / 5.678 us  (n=1000)" -> 1.234
stage_p50 () {
    grep -a -- "$2 p50/p99" "$1" 2>/dev/null | head -1 \
      | sed -E 's/.*: *([0-9.eE+-]+) *\/.*/\1/' | grep -E '^[0-9.]' || true
}

warm_clocks () {
    local r peak
    echo "warmup: ramping under load, target ${MIN_SM_MHZ} MHz"
    for r in $(seq 1 6); do
        clean_all
        start_clock_sampler
        timeout 200 $SERVER --port $PORT --bufsize 1048576 --n-buffers 400 \
            --warmup 100 --out /dev/null --transport shmem --one-shot \
            --zero-copy >/dev/null 2>&1 &
        local spid=$!
        sleep 4
        timeout 150 taskset -c 11 $CLIENT --server "localhost:$PORT" \
            --transport shmem --bufsize 1048576 --n-buffers 400 \
            --warmup 100 --pace-us $PACE >/dev/null 2>&1
        wait $spid 2>/dev/null
        peak=$(stop_clock_sampler)
        echo "  warmup round $r: peak ${peak:-?} MHz"
        [ -n "$peak" ] && [ "$peak" -ge "$MIN_SM_MHZ" ] && return 0
    done
    return 1
}

run_cell () {   # run_cell <arm> <size> <rep>
    local arm=$1 size=$2 rep=$3
    local tag="${arm}_${size}_${rep}"
    local csv="$LOGDIR/$tag.csv"
    local log="$LOGDIR/$tag.log"
    rm -f "$csv"
    clean_all
    start_clock_sampler

    case "$arm" in
      daq)
        timeout 400 $DAQ --yaml daqiri/config_roce_pipeline.yaml \
            --bufsize "$size" --n-buffers $N --warmup $W --pace-us $PACE \
            --zero-copy --stage-timing --out "$csv" > "$log" 2>&1
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3)
        ;;
      extbuf)
        timeout 400 $EXSRV --addr $RDMA_IP --port 18851 --npts "$size" \
            --warmup $W --msgs $N --slots 4 --csv "$csv" --sha "$GITSHA" \
            --verify off > "$log" 2>&1 &
        local sp=$!
        sleep 3
        # The client's --msgs is the TOTAL it sends and its --warmup only says
        # which of those it declines to time. The server's --msgs is the count
        # it wants AFTER its own warmup. So the client has to be asked for
        # W + N or the server records only N - W rows and ends on its linger
        # timer. This was passing --msgs $N, which is why the extbuf cells in
        # the first stage sweep show n=500 against 1000 for every other arm:
        # a short run, not a lossy one. headline_sweep.sh had this right.
        ( cd /tmp && GRPC_DIRECT_RDMA_LOCAL=$RDMA_IP timeout 300 $EXCLI \
            --host $RDMA_IP --port 18851 --npts "$size" --warmup $W \
            --msgs $((W + N)) \
            --pace-us $PACE --linger-ms 400 --gen inplace ) >> "$log" 2>&1
        wait $sp 2>/dev/null
        e2e=$(col_p50 "$csv" 5); fft=$(col_p50 "$csv" 6)
        ;;
      base|opt)
        local FL="--zero-copy --stage-timing"
        [ "$arm" = base ] && FL="--zero-copy --no-zc-align --no-opt-stream --stage-timing"
        timeout 400 $SERVER --port $PORT --bufsize "$size" --n-buffers $N \
            --warmup $W --out "$csv" --transport shmem --one-shot $FL \
            > "$log" 2>&1 &
        local sp=$!
        sleep 4
        timeout 300 taskset -c 11 $CLIENT --server "localhost:$PORT" \
            --transport shmem --bufsize "$size" --n-buffers $N --warmup $W \
            --pace-us $PACE >> "$log" 2>&1
        wait $sp 2>/dev/null
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3)
        ;;
    esac

    local mhz; mhz=$(stop_clock_sampler)
    clean_all
    local look real fcall nmsg
    look=$(stage_p50  "$log" "register+lookup")
    real=$(stage_p50  "$log" "realign enqueue")
    fcall=$(stage_p50 "$log" "fft call (wall)")
    nmsg=$(tail -n +2 "$csv" 2>/dev/null | wc -l)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$arm" "$size" "$rep" "${e2e:-NA}" "${fft:-NA}" "${look:-NA}" \
        "${real:-NA}" "${fcall:-NA}" "${nmsg:-0}" "${mhz:-NA}" "$PACE" "$GITSHA" \
        >> "$OUT"
    printf '  %-7s %8s r%s  e2e=%-9s fft=%-9s lookup=%-8s realign=%-8s fftcall=%-9s n=%-5s %sMHz\n' \
        "$arm" "$size" "$rep" "${e2e:-NA}" "${fft:-NA}" "${look:-NA}" \
        "${real:-NA}" "${fcall:-NA}" "${nmsg:-0}" "${mhz:-NA}"
}

echo "arm,size,rep,e2e_p50,fft_p50,lookup_p50,realign_p50,fftcall_p50,n,sm_mhz,pace_us,gitsha" > "$OUT"
warm_clocks || echo "WARNING: clocks did not reach ${MIN_SM_MHZ} MHz"

# Arms rotate within each rep. The GB10's clocks cannot be locked, so a sweep
# that ran all reps of one arm before starting the next would confound arm with
# thermal state.
for rep in $(seq 1 "$REPS"); do
    for size in $SIZES; do
        echo "== rep $rep  size $size =="
        for arm in $ARMS; do
            run_cell "$arm" "$size" "$rep"
        done
    done
done
echo "DONE -> $OUT"
