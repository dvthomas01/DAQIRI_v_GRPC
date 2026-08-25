#!/usr/bin/env bash
# Payload sweep with a three-term decomposition, for three arms.
#
# THE QUESTION
# Where does each transport actually win, and how does the time split between
# getting the data ready, moving it, and transforming it. Every table before
# this one reported only the receiver-side window (buffer in hand -> post-FFT),
# which silently excludes the two terms that differ most between the arms.
#
# THE THREE TERMS, per message
#   fill_us        the sender putting one message's samples where the transport
#                  will read them. The signal itself is synthesised once at
#                  startup in all three arms, so this is the only per-message
#                  data-creation cost any of them has.
#   transport_us   the sender's clock immediately before it hands the message
#                  off, to the receiver's clock the instant the message is in
#                  hand. One-way, no round trip, no calibration subtraction.
#   e2e_us         receiver-side, buffer in hand -> post-FFT gate. Unchanged
#                  from every earlier table, so those stay comparable.
#   fft_us         the cuFFT kernels alone, from CUDA events. A subset of
#                  e2e_us, not an addition to it.
#
#   full pipeline  = fill_us + transport_us + e2e_us
#
# WHY transport_us IS MEASURABLE AT ALL
# All three arms run both ends on this one box, so all three clock differences
# are raw CLOCK_MONOTONIC (or, for the gRPC arm, CLOCK_REALTIME) subtractions
# between two readings of the same clock. Nothing is synchronised because
# nothing needs to be. On a two-machine link none of this holds and the echo
# instrument is the only honest option.
#
# THE ONE ACCOUNTING ASYMMETRY, STATED UP FRONT
# DAQiri's sender memcpys straight into the NIC-registered buffer, so its single
# payload copy lands in fill_us. The gRPC-over-RDMA client runs --gen inplace,
# so its sender writes only a 16-byte header and the single payload copy happens
# inside the send library, which puts it in transport_us. Both arms do one copy.
# The total is comparable; the split between fill and transport is not, and the
# table has to say so. --gen inplace is kept rather than --gen copy because copy
# would make that arm do the work twice, and because every earlier sweep used
# inplace.
#
# REPS
# The settle sweep put the single-cell standard deviation at 4.4 us at 4 MiB and
# the paired within-rep difference at 5.5 us, which means three reps resolve a
# sign and not a magnitude. Six is the smallest count that also divides evenly
# by three arms, so every arm sits in every position exactly twice.
set -u
cd "$HOME/daqiri_gpu" || exit 1

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
DAQ=build/daqiri/bench_daqiri_roce_pipeline
EXSRV=/tmp/extbuf_fft_server
EXCLI=/tmp/extbuf_fft_client
RDMA_IP=192.168.20.1

SIZES="${SIZES:-4096 16384 65536 262144 1048576}"
ARMS="${ARMS:-opt extbuf daq}"
REPS="${REPS:-6}"
N="${N:-1000}"; W="${W:-500}"; PACE="${PACE:-25}"
# fixed: one pace for every size, 25 us, which is what every earlier table used.
#        Two of the three arms saturate under it at some sizes (see below), so
#        the transport column from a fixed pass is a queueing measurement.
# rate:  pace derived from the message size so that all sizes are offered at the
#        same byte rate, below every arm's capacity. This is the only setting
#        under which transport_us means one-way latency rather than backlog.
PACE_MODE="${PACE_MODE:-rate}"
# 780 B/us is one eighth of the 6249 B/us the RoCE link sustains, so the offered
# rate is an eighth of the wire's capacity at every size. An earlier attempt at
# one third of capacity was still too fast: at 16384 samples the RDMA arm's
# transport ran 169 / 805 / 2066 us at p05 / p50 / p95, which is a queue, not a
# latency. The binding constraint at small sizes is per-message overhead rather
# than bandwidth, which is what the 500 us floor is for.
OFFER_B_PER_US="${OFFER_B_PER_US:-780}"
PACE_FLOOR="${PACE_FLOOR:-500}"
PORT="${PORT:-50181}"; EXPORT_="${EXPORT_:-18861}"
OUT="${OUT:-data/payload_runs.csv}"
LOGDIR="${LOGDIR:-/tmp/payload}"
GITSHA="${GITSHA:-unknown}"
MIN_SM_MHZ="${MIN_SM_MHZ:-2400}"
mkdir -p "$LOGDIR" data

# WHY PACING HAD TO CHANGE
# Only one of these three arms applies end-to-end backpressure. The RDMA arm
# runs on a four-slot credit scheme, so its sender blocks and its queue cannot
# grow. The other two have no such thing: the gRPC shared-memory ring is
# fire-and-forget and silently drops when the client outruns the handler (a
# 65536-sample smoke run at pace 25 lost 83 of 300 messages), and the DAQiri
# sender posts into a deep receive window, so an over-driven link turns into a
# queue rather than a loss (the same smoke run read 10910 us of transport, which
# is the backlog, not the wire).
#
# None of that was visible before, because every earlier table measured only the
# receiver-side window, which starts after the buffer is already in hand. A
# backlog is invisible from inside it. Measuring transport is what exposed it.
#
# So the default is now a size-derived pace holding the offered rate at an
# eighth of the link's capacity, with a floor of 500 us so the small sizes are
# not limited by per-message overhead instead. Nobody saturates, so all three
# transport numbers mean the same thing. Run with PACE_MODE=fixed to reproduce
# the old regime and see the saturation behaviour instead.
cell_pace () {   # cell_pace <size>
    if [ "$PACE_MODE" = rate ]; then
        local p=$(( ($1 * 4) / OFFER_B_PER_US ))
        [ "$p" -lt "$PACE_FLOOR" ] && p=$PACE_FLOOR
        echo "$p"
    else
        echo "$PACE"
    fi
}

# Every one of these guards exists because the alternative is a clean,
# publishable, wrong number from a stale binary.
grep -qa 'payload fill p50' "$CLIENT" || {
    echo "ABORT: $CLIENT has no fill timer. Rebuild:"
    echo "  cmake --build ~/daqiri_gpu/build_grpc --parallel 16 --target bench_grpc_client"
    exit 1; }
grep -qa 'payload fill p50' "$DAQ" || {
    echo "ABORT: $DAQ has no fill timer. Rebuild:"
    echo "  cmake --build ~/daqiri_gpu/build --parallel 16 --target bench_daqiri_roce_pipeline"
    exit 1; }
grep -qa 'transport_us' "$EXSRV" || {
    echo "ABORT: $EXSRV predates the header timestamp. Rebuild:"
    echo "  bash scripts/build_extbuf_server.sh"
    exit 1; }
# The client has no distinctive new string to grep for, so fall back to mtime
# against both files that changed. A client built before the header field would
# leave send_ts_ns as whatever the frame happened to contain.
for f in rdma/extbuf_fft_client.cc rdma/rdma_contract.h; do
    if [ "$f" -nt "$EXCLI" ]; then
        echo "ABORT: $f is newer than $EXCLI. Rebuild:"
        echo "  bash scripts/build_extbuf_client.sh"
        exit 1
    fi
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
      | awk '{v[n++]=$1} END{ if(n) printf "%.3f", v[int(0.5*(n-1))] }'
}

# Transport gets percentiles rather than a median, because one arm's transport
# is not unimodal. DAQiri's receive completions become visible to the
# application in bursts a few milliseconds apart: within a burst every message
# is handed over at nearly the same instant, so the reported age falls by
# exactly one send interval per message and then jumps back up. Measured at
# 65536 samples with the sender limited to one message in flight, pacing at
# 1000 us: 3888, 2857, 1821, 783, then 6610, 3915, 2877, 1839. The steps are
# 1035 us, which is the send interval, so the four messages of a burst arrived
# together. A median off that distribution reports where the median message sat
# in its burst and nothing else. p05 is the closest thing to a floor.
#
# The RDMA arm on the same NIC does not do this, so it is the DAQiri receive
# path rather than the hardware or the loopback.
col_pct () {   # col_pct <csv> <1-based field> <fraction>
    tail -n +2 "$1" 2>/dev/null | cut -d, -f"$2" | grep -E '^[0-9.]+$' | sort -g \
      | awk -v p="$3" '{v[n++]=$1} END{ if(n) printf "%.3f", v[int(p*(n-1))] }'
}

# The sender prints its own fill median because the CSV belongs to the receiver.
# Split on the FIRST colon only: the extbuf line carries a second one inside its
# parenthetical, which a greedy regex would latch onto.
fill_p50 () {
    grep -a -E 'payload fill p50|frame build p50' "$1" 2>/dev/null | head -1 \
      | awk -F': *' '{print $2}' | awk '{print $1}' | grep -E '^[0-9.]' || true
}

# The GB10 parks at idle clocks and ramps about three seconds into sustained
# load, so the clock has to be sampled DURING the cell.
CLK_PID=""
start_clock_sampler () {
    : > /tmp/pl_clk.txt
    ( while :; do
        nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null
        sleep 0.2
      done >> /tmp/pl_clk.txt ) &
    CLK_PID=$!
}
stop_clock_sampler () {
    [ -n "$CLK_PID" ] && kill "$CLK_PID" 2>/dev/null
    wait "$CLK_PID" 2>/dev/null
    CLK_PID=""
    tr -dc '0-9\n' < /tmp/pl_clk.txt | grep -E '^[0-9]+$' | sort -n | tail -1
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

run_cell () {   # run_cell <arm> <size> <rep> <pos>
    local arm=$1 size=$2 rep=$3 pos=$4
    local tag="${arm}_${size}_${rep}"
    local csv="$LOGDIR/$tag.csv"
    local log="$LOGDIR/$tag.log"
    # The sender gets its own file. Both processes hold the same log open, and
    # the receiver's redirect is a truncating one rather than an append, so its
    # end-of-run summary writes at its own offset and overwrites whatever the
    # sender appended earlier. That is why the first smoke run reported no fill
    # figure for the gRPC arm: the client had printed it and the server had
    # written over it.
    local clog="$LOGDIR/$tag.sender.log"
    local e2e fft wire pace wcol wlo whi
    pace=$(cell_pace "$size")
    rm -f "$csv" "$clog"
    clean_all
    start_clock_sampler

    case "$arm" in
      daq)
        timeout 400 $DAQ --yaml daqiri/config_roce_pipeline.yaml \
            --bufsize "$size" --n-buffers $N --warmup $W --pace-us $pace \
            --zero-copy --out "$csv" > "$log" 2>&1
        cp "$log" "$clog"   # one process, so sender and receiver share a log
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3); wcol=11
        ;;
      extbuf)
        timeout 400 $EXSRV --addr $RDMA_IP --port $EXPORT_ --npts "$size" \
            --warmup $W --msgs $N --slots 4 --csv "$csv" --sha "$GITSHA" \
            --verify off > "$log" 2>&1 &
        local sp=$!
        sleep 3
        # The client's --msgs is the TOTAL it sends; the server's is the count it
        # wants AFTER its own warmup. Asking the client for N alone is what made
        # the first stage sweep record 500 rows against 1000 everywhere else.
        ( cd /tmp && GRPC_DIRECT_RDMA_LOCAL=$RDMA_IP timeout 300 $EXCLI \
            --host $RDMA_IP --port $EXPORT_ --npts "$size" --warmup $W \
            --msgs $((W + N)) \
            --pace-us $pace --linger-ms 400 --gen inplace ) > "$clog" 2>&1
        wait $sp 2>/dev/null
        e2e=$(col_p50 "$csv" 5); fft=$(col_p50 "$csv" 6); wcol=11
        ;;
      opt)
        timeout 400 $SERVER --port $PORT --bufsize "$size" --n-buffers $N \
            --warmup $W --out "$csv" --transport shmem --one-shot \
            --zero-copy > "$log" 2>&1 &
        local sp=$!
        sleep 4
        timeout 300 taskset -c 11 $CLIENT --server "localhost:$PORT" \
            --transport shmem --bufsize "$size" --n-buffers $N --warmup $W \
            --pace-us $pace > "$clog" 2>&1
        wait $sp 2>/dev/null
        e2e=$(col_p50 "$csv" 1); fft=$(col_p50 "$csv" 3); wcol=11
        ;;
    esac

    wire=$(col_pct "$csv" "$wcol" 0.50)
    wlo=$(col_pct  "$csv" "$wcol" 0.05)
    whi=$(col_pct  "$csv" "$wcol" 0.95)

    local mhz; mhz=$(stop_clock_sampler)
    clean_all
    local fill nmsg
    fill=$(fill_p50 "$clog")
    nmsg=$(tail -n +2 "$csv" 2>/dev/null | wc -l)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$arm" "$size" "$rep" "$pos" "${fill:-NA}" "${wlo:-NA}" "${wire:-NA}" \
        "${whi:-NA}" "${e2e:-NA}" "${fft:-NA}" "${nmsg:-0}" "${mhz:-NA}" \
        "$pace" "$GITSHA" >> "$OUT"
    printf '  %-7s %8s r%s p%s pace=%-5s fill=%-8s wire=%-9s/%-9s/%-9s e2e=%-8s fft=%-8s n=%-5s %sMHz\n' \
        "$arm" "$size" "$rep" "$pos" "$pace" "${fill:-NA}" "${wlo:-NA}" \
        "${wire:-NA}" "${whi:-NA}" "${e2e:-NA}" "${fft:-NA}" "${nmsg:-0}" "${mhz:-NA}"
}

# Rotate the arm list left by (rep-1) mod NARM so each arm occupies each slot in
# the rep an equal number of times. The settle sweep measured the position
# effect at 1.5 us, small but not zero, and it is free to balance it away.
NARM=$(set -- $ARMS; echo $#)
rot_arms () {   # rot_arms <rep>
    local k=$(( ($1 - 1) % NARM )) i=0 head="" tail=""
    for a in $ARMS; do
        if [ $i -lt $k ]; then tail="$tail $a"; else head="$head $a"; fi
        i=$((i + 1))
    done
    echo "$head$tail"
}

echo "arm,size,rep,pos,fill_p50,transport_p05,transport_p50,transport_p95,e2e_p50,fft_p50,n,sm_mhz,pace_us,gitsha" > "$OUT"
warm_clocks || echo "WARNING: clocks did not reach ${MIN_SM_MHZ} MHz"

for rep in $(seq 1 "$REPS"); do
    for size in $SIZES; do
        echo "== rep $rep  size $size =="
        pos=1
        for arm in $(rot_arms "$rep"); do
            run_cell "$arm" "$size" "$rep" "$pos"
            pos=$((pos + 1))
        done
    done
done
echo "DONE -> $OUT"
