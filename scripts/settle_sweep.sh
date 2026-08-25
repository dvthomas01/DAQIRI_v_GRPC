#!/bin/sh
# Settle the opt-vs-DAQiri disagreement at 4 MiB.
#
# Two of our own measurements disagree. Table B (handoff 7n, data/tableB_
# interleaved.csv) puts opt and daq within 0.86 us of each other at 4 MiB. The
# stage sweep (data/stage_runs.csv) puts them 12.99 us apart, 3 reps out of 3,
# with non-overlapping ranges. Both ran N=1000, W=500, PACE=25, 3 reps, arms
# rotated inside each rep, so the conditions were not the difference.
#
# The obvious suspect is that bench_daqiri_roce_pipeline was rebuilt between the
# two. Two things argue against it before any new data is taken. First, pairing
# the two tables rep by rep, opt minus daq is +0.03, +0.86, +14.72 in Table B
# and +2.53, +14.08, +13.15 in the stage sweep: six positive differences out of
# six, but split into a cluster near zero and a cluster near 14. That is a
# bimodal quantity, and a 3-rep median is the wrong estimator for one. Second,
# base, opt and extbuf were NOT rebuilt and still moved -2.92, +6.37 and -7.26
# us between the two sweeps, so between-sweep drift of that size happens with no
# rebuild at all.
#
# This script tests the rebuild directly anyway, and buys enough reps to see the
# shape rather than a median of three. Four arms in one rotation:
#
#   daqpre  reconstructed pre-stage-timing source, built by scripts/
#           build_daq_pre.sh from the same toolchain and CMake configuration
#   daqoff  current binary, timers compiled in but not enabled
#   daqon   current binary, --stage-timing enabled
#   opt     gRPC optimized, no stage timing, exactly as Table B ran it
#
# daqpre vs daqoff isolates the source change. daqoff vs daqon isolates the cost
# of taking the timestamps. Either of the daq arms against opt is the question
# that actually matters, now with REPS paired observations instead of three.
#
# Arm ORDER inside the rep is rotated, which the earlier sweeps did not do. They
# ran base, opt, daq, extbuf in that fixed order every rep, so each arm always
# sat in the same position after clean_all and any drift across a rep was
# charged to whichever arm happened to occupy that slot. A first pass of this
# script showed the position-1 arm coming out about 6 us faster than position 2,
# which is the size of the effect under investigation, so the order cannot be
# left fixed. With 4 arms, REPS should be a multiple of 4 for exact balance.
# The position is written into every row so the effect can be measured.
set -u
cd "$HOME/daqiri_gpu" || exit 1

SIZE="${SIZE:-1048576}"
ARMS="${ARMS:-daqpre daqoff daqon opt}"
REPS="${REPS:-12}"
N="${N:-1000}"
W="${W:-500}"
PACE="${PACE:-25}"
PORT="${PORT:-50171}"
OUT="${OUT:-data/settle_runs.csv}"
LOGDIR="${LOGDIR:-/tmp/settle}"
GITSHA="${GITSHA:-settle}"
MIN_SM_MHZ="${MIN_SM_MHZ:-2400}"

DAQ=build/daqiri/bench_daqiri_roce_pipeline
DAQPRE=build/daqiri/bench_daqiri_roce_pipeline_pre
SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client

mkdir -p "$LOGDIR" data
for b in "$DAQ" "$DAQPRE" "$SERVER" "$CLIENT"; do
    [ -x "$b" ] || { echo "ABORT: missing $b"; exit 1; }
done
grep -qa -- '--stage-timing' "$DAQ"    || { echo "ABORT: $DAQ lacks --stage-timing"; exit 1; }
grep -qa -- '--stage-timing' "$DAQPRE" && { echo "ABORT: $DAQPRE has --stage-timing"; exit 1; }

clean_all () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

col_p50 () {
    tail -n +2 "$1" 2>/dev/null | cut -d, -f"$2" | grep -E '^[0-9.]+$' | sort -g \
      | awk '{v[n++]=$1} END{ if(n) printf "%.3f", v[int(0.5*(n-1))] }'
}

CLK_PID=""
start_clock_sampler () {
    : > /tmp/se_clk.txt
    ( while :; do
        nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null
        sleep 0.2
      done >> /tmp/se_clk.txt ) &
    CLK_PID=$!
}
stop_clock_sampler () {
    [ -n "$CLK_PID" ] && kill "$CLK_PID" 2>/dev/null
    wait "$CLK_PID" 2>/dev/null
    CLK_PID=""
    tr -dc '0-9\n' < /tmp/se_clk.txt | grep -E '^[0-9]+$' | sort -n | tail -1
}

warm_clocks () {
    r=1
    echo "warmup: ramping under load, target ${MIN_SM_MHZ} MHz"
    while [ $r -le 6 ]; do
        clean_all
        start_clock_sampler
        timeout 200 $SERVER --port $PORT --bufsize 1048576 --n-buffers 400 \
            --warmup 100 --out /dev/null --transport shmem --one-shot \
            --zero-copy >/dev/null 2>&1 &
        spid=$!
        sleep 4
        timeout 150 taskset -c 11 $CLIENT --server "localhost:$PORT" \
            --transport shmem --bufsize 1048576 --n-buffers 400 \
            --warmup 100 --pace-us $PACE >/dev/null 2>&1
        wait $spid 2>/dev/null
        peak=$(stop_clock_sampler)
        echo "  warmup round $r: peak ${peak:-?} MHz"
        [ -n "$peak" ] && [ "$peak" -ge "$MIN_SM_MHZ" ] && return 0
        r=$((r + 1))
    done
    return 1
}

# ARMS rotated left by k, so that over a multiple of 4 reps every arm occupies
# every position in the rep the same number of times.
rot_arms () {
    k=$1
    if [ "$k" -eq 0 ]; then echo $ARMS; return; fi
    echo "$(echo $ARMS | cut -d' ' -f$((k + 1))-) $(echo $ARMS | cut -d' ' -f1-$k)"
}

run_cell () {   # run_cell <arm> <rep> <position>
    arm=$1; rep=$2; pos=$3
    csv="$LOGDIR/${arm}_${rep}.csv"
    log="$LOGDIR/${arm}_${rep}.log"
    rm -f "$csv"
    clean_all
    start_clock_sampler

    case "$arm" in
      daqpre)
        timeout 400 $DAQPRE --yaml daqiri/config_roce_pipeline.yaml \
            --bufsize "$SIZE" --n-buffers $N --warmup $W --pace-us $PACE \
            --zero-copy --out "$csv" > "$log" 2>&1
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3)
        ;;
      daqoff)
        timeout 400 $DAQ --yaml daqiri/config_roce_pipeline.yaml \
            --bufsize "$SIZE" --n-buffers $N --warmup $W --pace-us $PACE \
            --zero-copy --out "$csv" > "$log" 2>&1
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3)
        ;;
      daqon)
        timeout 400 $DAQ --yaml daqiri/config_roce_pipeline.yaml \
            --bufsize "$SIZE" --n-buffers $N --warmup $W --pace-us $PACE \
            --zero-copy --stage-timing --out "$csv" > "$log" 2>&1
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3)
        ;;
      opt)
        timeout 400 $SERVER --port $PORT --bufsize "$SIZE" --n-buffers $N \
            --warmup $W --out "$csv" --transport shmem --one-shot \
            --zero-copy > "$log" 2>&1 &
        sp=$!
        sleep 4
        timeout 300 taskset -c 11 $CLIENT --server "localhost:$PORT" \
            --transport shmem --bufsize "$SIZE" --n-buffers $N --warmup $W \
            --pace-us $PACE >> "$log" 2>&1
        wait $sp 2>/dev/null
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3)
        ;;
    esac

    mhz=$(stop_clock_sampler)
    clean_all
    nmsg=$(tail -n +2 "$csv" 2>/dev/null | wc -l)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$arm" "$SIZE" "$rep" "$pos" "${e2e:-NA}" "${fft:-NA}" "${nmsg:-0}" \
        "${mhz:-NA}" "$GITSHA" >> "$OUT"
    printf '  %-7s r%-3s pos%s e2e=%-10s fft=%-10s n=%-6s %sMHz\n' \
        "$arm" "$rep" "$pos" "${e2e:-NA}" "${fft:-NA}" "${nmsg:-0}" "${mhz:-NA}"
}

echo "arm,size,rep,pos,e2e_p50,fft_p50,n,sm_mhz,gitsha" > "$OUT"
NARM=$(echo $ARMS | wc -w)
warm_clocks || echo "WARNING: clocks did not reach ${MIN_SM_MHZ} MHz"

rep=1
while [ "$rep" -le "$REPS" ]; do
    ORDER=$(rot_arms $(( (rep - 1) % NARM )))
    echo "== rep $rep ==  order: $ORDER"
    pos=1
    for arm in $ORDER; do
        run_cell "$arm" "$rep" "$pos"
        pos=$((pos + 1))
    done
    rep=$((rep + 1))
done
echo "DONE -> $OUT"
