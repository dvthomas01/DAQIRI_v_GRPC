#!/usr/bin/env bash
# Does --own-stream help the external-buffer receiver?
#
# --own-stream is the same optimization the shared-memory server calls
# --opt-stream: CuFFTExecutor builds a cudaStreamNonBlocking stream, binds the
# plan to it with cufftSetStream, and waits by spinning on cudaEventQuery
# instead of parking the thread in cudaEventSynchronize. It already exists in
# extbuf_fft_server.cu; it is simply off by default, so every sweep so far ran
# without it. Nothing needed adding, only measuring.
#
# The number to watch is the RESIDUAL, e2e minus fft. That is the host-side
# window either side of the transform, which is the only part a stream and a
# wait policy can move. The shared-memory arm won 0.15 to 0.39 us there, so the
# effect being looked for is small and the design has to be able to see it.
#
# Design, following what the settle sweep established:
#   - a single cell has ~4.4 us SD, so a single pair proves nothing
#   - REPS pairs, and the two variants SWAP ORDER every rep, so any drift in
#     clock or thermals lands on both equally
#   - paired within-rep differences, plus a sign test, never a bare median
#   - SM clock recorded per cell so a downclock cannot be mistaken for a result
set -u
cd "$HOME/daqiri_gpu" || exit 1

SIZES="${SIZES:-4096 262144 1048576}"
REPS="${REPS:-8}"
N="${N:-1000}"
W="${W:-500}"
PORT="${PORT:-18871}"
RDMA_IP="${RDMA_IP:-192.168.20.1}"
GITSHA="${GITSHA:-unknown}"
OUT="${OUT:-data/extbuf_stream_ab.csv}"
LOGDIR="${LOGDIR:-/tmp/exstream}"
EXSRV="${EXSRV:-/tmp/extbuf_fft_server}"
EXCLI="${EXCLI:-/tmp/extbuf_fft_client}"

# Same unsaturated pacing rule the payload sweep used: one eighth of the link's
# 6249 B/us, with a floor because at small sizes the binding constraint is
# per-message overhead rather than bandwidth.
OFFER_B_PER_US="${OFFER_B_PER_US:-780}"
PACE_FLOOR="${PACE_FLOOR:-500}"

mkdir -p "$LOGDIR"

for f in "$EXSRV" "$EXCLI"; do
    [ -x "$f" ] || { echo "ABORT: $f missing"; exit 1; }
done
grep -qa 'own-stream' "$EXSRV" || {
    echo "ABORT: $EXSRV has no --own-stream flag. Rebuild with scripts/build_extbuf_server.sh"
    exit 1
}

clean_all () {
    pkill -9 -f extbuf_fft_server 2>/dev/null
    pkill -9 -f extbuf_fft_client 2>/dev/null
    sleep 1
}
trap 'clean_all; exit 130' INT TERM

cell_pace () {
    # Two statements, not one. `local a=$1 b=$((a*4))` expands every argument
    # before any of the assignments take effect, so b would be computed from an
    # unset a, which under set -u aborts the whole run.
    local sz=$1
    local p=$(( sz * 4 / OFFER_B_PER_US ))
    [ "$p" -lt "$PACE_FLOOR" ] && p=$PACE_FLOOR
    echo "$p"
}

col_p50 () {  # col_p50 <csv> <field>
    tail -n +2 "$1" 2>/dev/null | cut -d, -f"$2" \
      | awk 'NF' | sort -n | awk '{v[NR]=$1} END{if(NR)printf "%.3f", v[int(NR/2)+1]}'
}

sm_mhz () { nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null | head -1; }

# One run of the receiver plus its sender. variant is "on" or "off".
run_cell () {  # run_cell <variant> <size> <rep> <pos>
    local variant=$1 size=$2 rep=$3 pos=$4
    local tag="${variant}_${size}_r${rep}"
    local csv="$LOGDIR/$tag.csv"
    local log="$LOGDIR/$tag.server.log"
    local clog="$LOGDIR/$tag.sender.log"
    local pace; pace=$(cell_pace "$size")
    local flag=""
    [ "$variant" = "on" ] && flag="--own-stream"

    rm -f "$csv" "$log" "$clog"
    clean_all

    timeout 400 $EXSRV --addr $RDMA_IP --port $PORT --npts "$size" \
        --warmup $W --msgs $N --slots 4 --csv "$csv" --sha "$GITSHA" \
        --verify off $flag > "$log" 2>&1 &
    local sp=$!
    sleep 3
    ( cd /tmp && GRPC_DIRECT_RDMA_LOCAL=$RDMA_IP timeout 300 $EXCLI \
        --host $RDMA_IP --port $PORT --npts "$size" --warmup $W \
        --msgs $((W + N)) --pace-us $pace --linger-ms 400 --gen inplace ) \
        > "$clog" 2>&1
    wait $sp 2>/dev/null

    local e2e fft mhz n
    e2e=$(col_p50 "$csv" 5)
    fft=$(col_p50 "$csv" 6)
    mhz=$(sm_mhz)
    n=$(tail -n +2 "$csv" 2>/dev/null | wc -l)
    local res=""
    [ -n "$e2e" ] && [ -n "$fft" ] && res=$(awk -v a="$e2e" -v b="$fft" 'BEGIN{printf "%.3f", a-b}')

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$variant" "$size" "$rep" "$pos" "${e2e:-NA}" "${fft:-NA}" \
        "${res:-NA}" "${n:-0}" "${mhz:-NA}" "$GITSHA" >> "$OUT"
    printf '  %-3s %8s r%-2s p%s  e2e=%-8s fft=%-8s residual=%-8s n=%-5s %sMHz\n' \
        "$variant" "$size" "$rep" "$pos" "${e2e:-NA}" "${fft:-NA}" \
        "${res:-NA}" "${n:-0}" "${mhz:-NA}"
}

echo "variant,size,rep,pos,e2e_p50,fft_p50,residual,n,sm_mhz,gitsha" > "$OUT"
echo "sizes=$SIZES reps=$REPS n=$N warmup=$W sha=$GITSHA"

for rep in $(seq 1 "$REPS"); do
    for size in $SIZES; do
        echo "== rep $rep  size $size  pace $(cell_pace "$size") =="
        # Swap which variant goes first every rep, so position cannot favour one.
        if [ $(( rep % 2 )) -eq 1 ]; then
            run_cell on  "$size" "$rep" 1
            run_cell off "$size" "$rep" 2
        else
            run_cell off "$size" "$rep" 1
            run_cell on  "$size" "$rep" 2
        fi
    done
done

clean_all
echo "DONE -> $OUT"
