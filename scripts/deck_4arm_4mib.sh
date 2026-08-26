#!/bin/sh
# Four-arm 4 MiB comparison at 12 reps, for the part-3 headline chart.
#
# WHY THIS EXISTS
# The only 12-rep data at 4 MiB (data/settle_runs.csv) has opt plus three
# interchangeable DAQiri builds. It has no base and no extbuf, because it was
# built to test whether a rebuild had changed DAQiri. The four-arm comparison
# exists only at 3 reps, and handoff 7r established that 3 reps at 4 MiB cannot
# resolve anything under about 8 us: single-cell SD is 4.4 us and the paired
# within-rep SD is 5.5. A headline chart with error bars needs real reps.
#
# DESIGN, inherited from settle_sweep.sh because that one worked
#   - 4 MiB only, REPS=12, a multiple of 4 so every arm sits in every position
#     exactly 3 times. Position is recorded in every row.
#   - Clock sampler per cell, peak SM MHz recorded, warm-up loop before the run.
#   - clean_all between every cell.
#
# TWO PACING REGIMES, and this is the part that is NOT optional.
# handoff 7n found extbuf's transform triples between 100 and 400 us of send
# pacing while DAQiri's does not move. So pacing is a treatment that acts on one
# arm and not another, and any single choice of pace silently picks a winner.
# The 4 MiB payload sweep shows the size of it: extbuf e2e 81.59 at pace 25
# against 101.98 unsaturated, while daq moves 68.16 to 65.66 and opt 73.11 to
# 75.18. Choosing one pace and building a headline on it would repeat exactly
# the mistake 7n was written about, so both are measured and the chart has to
# say which one it is drawn from.
#   sat    pace 25 us. Comparable to Table B and the settle sweep, which both
#          used 25. At 4 MiB the wire time is ~671 us, so 25 is 27x faster than
#          the link and the pipeline is saturated: queueing is in the number.
#   unsat  pace from a 780 B/us offer rate, 5377 us at 4 MiB, about 8x the wire
#          time. No queueing, but extbuf is inside its degradation region.
#
# ARM CONFIGURATION
#   base    --no-zc-align --no-opt-stream. Deliberately the before-picture.
#   opt     zc_align and opt_stream both default on.
#   daq     bench_daqiri_roce_pipeline.cc:352 constructs CuFFTExecutor(buf_size)
#           with own_stream defaulting false, and exposes no flag to change it.
#           DAQiri therefore runs WITHOUT the dedicated stream and cannot be
#           asked to run with it. At 4 MiB handoff 7w measured that flag at
#           -0.77 us, 3 of 8, so this costs DAQiri nothing here. State it anyway.
#   extbuf  --own-stream, which every previous extbuf measurement omitted
#           because extbuf_fft_server.cu:315 defaults it off and no sweep ever
#           passed it. Taking fresh data without it would bake that mismatch
#           into the headline chart.
set -u
cd "$HOME/daqiri_gpu" || exit 1

SIZE="${SIZE:-1048576}"          # samples; 4 MiB of float32
ARMS="${ARMS:-base opt daq extbuf}"
REPS="${REPS:-12}"
N="${N:-1000}"
W="${W:-500}"
MODES="${MODES:-sat unsat}"
SAT_PACE="${SAT_PACE:-25}"
OFFER_B_PER_US="${OFFER_B_PER_US:-780}"
PORT="${PORT:-50181}"
EXPORT_="${EXPORT_:-18881}"
RDMA_IP="${RDMA_IP:-192.168.20.1}"
OUT="${OUT:-data/deck_4arm_4mib.csv}"
LOGDIR="${LOGDIR:-/tmp/deck4}"
GITSHA="${GITSHA:-deck4}"
MIN_SM_MHZ="${MIN_SM_MHZ:-2400}"

DAQ=build/daqiri/bench_daqiri_roce_pipeline
SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
EXSRV="${EXSRV:-/tmp/extbuf_fft_server}"
EXCLI="${EXCLI:-/tmp/extbuf_fft_client}"

mkdir -p "$LOGDIR" data
for b in "$DAQ" "$SERVER" "$CLIENT" "$EXSRV" "$EXCLI"; do
    [ -x "$b" ] || { echo "ABORT: missing or not executable: $b"; exit 1; }
done
# The whole point of this run is that extbuf gets the flag. Fail loudly if the
# binary on disk predates it rather than silently measuring the old thing.
grep -qa -- 'own-stream' "$EXSRV" || {
    echo "ABORT: $EXSRV has no --own-stream. Rebuild it before running."; exit 1; }
grep -qa -- 'no-zc-align' "$SERVER" || {
    echo "ABORT: $SERVER has no --no-zc-align, cannot build the base arm."; exit 1; }

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

CLK_PID=""
start_clock_sampler () {
    : > /tmp/d4_clk.txt
    ( while :; do
        nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null
        sleep 0.2
      done >> /tmp/d4_clk.txt ) &
    CLK_PID=$!
}
stop_clock_sampler () {
    [ -n "$CLK_PID" ] && kill "$CLK_PID" 2>/dev/null
    wait "$CLK_PID" 2>/dev/null
    CLK_PID=""
    tr -dc '0-9\n' < /tmp/d4_clk.txt | grep -E '^[0-9]+$' | sort -n | tail -1
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
            --warmup 100 --pace-us 25 >/dev/null 2>&1
        wait $spid 2>/dev/null
        peak=$(stop_clock_sampler)
        echo "  warmup round $r: peak ${peak:-?} MHz"
        [ -n "$peak" ] && [ "$peak" -ge "$MIN_SM_MHZ" ] && return 0
        r=$((r + 1))
    done
    return 1
}

# Rotate ARMS left by k so that over a multiple of 4 reps every arm occupies
# every position the same number of times. settle_sweep found a 1.50 us position
# effect, which is small but the same order as some of the differences here.
rot_arms () {
    k=$1
    if [ "$k" -eq 0 ]; then echo $ARMS; return; fi
    echo "$(echo $ARMS | cut -d' ' -f$((k + 1))-) $(echo $ARMS | cut -d' ' -f1-$k)"
}

mode_pace () {
    # Split across statements: `local a=$1 b=$((a*2))` expands every argument
    # before any assignment takes effect, so b is computed from an unset a and
    # set -u aborts. That bug cost a run in the extbuf stream A/B.
    m=$1
    if [ "$m" = "sat" ]; then
        echo "$SAT_PACE"
    else
        bytes=$(( SIZE * 4 ))
        echo $(( bytes / OFFER_B_PER_US ))
    fi
}

run_cell () {   # run_cell <arm> <mode> <rep> <pos>
    arm=$1; mode=$2; rep=$3; pos=$4
    pace=$(mode_pace "$mode")
    tag="${arm}_${mode}_${rep}"
    csv="$LOGDIR/$tag.csv"
    log="$LOGDIR/$tag.log"
    clog="$LOGDIR/$tag.sender.log"
    rm -f "$csv" "$clog"
    clean_all
    start_clock_sampler

    case "$arm" in
      base|opt)
        if [ "$arm" = "base" ]; then
            FL="--zero-copy --no-zc-align --no-opt-stream"
        else
            FL="--zero-copy"
        fi
        timeout 400 $SERVER --port $PORT --bufsize "$SIZE" --n-buffers $N \
            --warmup $W --out "$csv" --transport shmem --one-shot \
            $FL > "$log" 2>&1 &
        sp=$!
        sleep 4
        timeout 300 taskset -c 11 $CLIENT --server "localhost:$PORT" \
            --transport shmem --bufsize "$SIZE" --n-buffers $N --warmup $W \
            --pace-us $pace > "$clog" 2>&1
        wait $sp 2>/dev/null
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3)
        ;;
      daq)
        timeout 400 $DAQ --yaml daqiri/config_roce_pipeline.yaml \
            --bufsize "$SIZE" --n-buffers $N --warmup $W --pace-us $pace \
            --zero-copy --out "$csv" > "$log" 2>&1
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3)
        ;;
      extbuf)
        timeout 400 $EXSRV --addr $RDMA_IP --port $EXPORT_ --npts "$SIZE" \
            --warmup $W --msgs $N --slots 4 --csv "$csv" --sha "$GITSHA" \
            --verify off --own-stream > "$log" 2>&1 &
        sp=$!
        sleep 3
        # The client's --msgs is the TOTAL it sends; the server's is the count
        # it wants AFTER its own warmup. Asking the client for N alone is what
        # made the first stage sweep record 500 rows against 1000. handoff 7t.
        ( cd /tmp && GRPC_DIRECT_RDMA_LOCAL=$RDMA_IP timeout 300 $EXCLI \
            --host $RDMA_IP --port $EXPORT_ --npts "$SIZE" --warmup $W \
            --msgs $((W + N)) \
            --pace-us $pace --linger-ms 400 --gen inplace ) > "$clog" 2>&1
        wait $sp 2>/dev/null
        e2e=$(col_p50 "$csv" 5); fft=$(col_p50 "$csv" 6)
        ;;
    esac

    mhz=$(stop_clock_sampler)
    clean_all
    nmsg=$(tail -n +2 "$csv" 2>/dev/null | wc -l)
    resid=$(awk -v a="${e2e:-}" -v b="${fft:-}" \
        'BEGIN{ if (a != "" && b != "") printf "%.3f", a - b }')
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$arm" "$mode" "$pace" "$SIZE" "$rep" "$pos" \
        "${e2e:-NA}" "${fft:-NA}" "${resid:-NA}" "${nmsg:-0}" \
        "${mhz:-NA}" "$GITSHA" >> "$OUT"
    printf '  %-7s %-5s r%-3s pos%s e2e=%-9s fft=%-9s resid=%-8s n=%-5s %sMHz\n' \
        "$arm" "$mode" "$rep" "$pos" "${e2e:-NA}" "${fft:-NA}" \
        "${resid:-NA}" "${nmsg:-0}" "${mhz:-NA}"
}

echo "arm,mode,pace_us,size,rep,pos,e2e_p50,fft_p50,resid,n,sm_mhz,gitsha" > "$OUT"
NARM=$(echo $ARMS | wc -w)
warm_clocks || echo "WARNING: clocks did not reach ${MIN_SM_MHZ} MHz"

for mode in $MODES; do
    echo "######## mode $mode  pace $(mode_pace "$mode") us ########"
    rep=1
    while [ "$rep" -le "$REPS" ]; do
        ORDER=$(rot_arms $(( (rep - 1) % NARM )))
        echo "== $mode rep $rep ==  order: $ORDER"
        pos=1
        for arm in $ORDER; do
            run_cell "$arm" "$mode" "$rep" "$pos"
            pos=$((pos + 1))
        done
        rep=$((rep + 1))
    done
done
echo "DONE -> $OUT"
