#!/usr/bin/env bash
# Same run twice: once with the receive loop sleeping between empty polls (the
# way every measurement so far was taken), once busy-polling. Everything else is
# identical, so any difference in the transport column belongs to the sleep and
# not to the network.
set -u
cd "$HOME/daqiri_gpu" || exit 1

SAMPLES=${1:-65536}
PACE=${2:-500}
N=${3:-900}
W=${4:-50}
BIN=build/daqiri/bench_daqiri_roce_pipeline

run() {
    local tag=$1; shift
    local log=/tmp/spin_$tag.log
    local csv=/tmp/spin_$tag.csv
    pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
    sleep 1
    timeout 240 "$BIN" --yaml daqiri/config_roce_pipeline.yaml \
        --bufsize "$SAMPLES" --n-buffers "$N" --warmup "$W" \
        --pace-us "$PACE" --zero-copy --trace-rx 600 \
        --out "$csv" "$@" > "$log" 2>&1
    local ex=$?

    # transport is field 11, e2e field 1, fft field 3
    local stats
    stats=$(tail -n +2 "$csv" | awk -F, '
        {t[NR]=$11; e[NR]=$1; f[NR]=$3}
        END {
            if (NR<10) { print "no rows"; exit }
            n=asort(t); asort(e); asort(f)
            printf "n=%d  transport p05/p50/p95 = %.0f / %.0f / %.0f us   e2e p50 = %.1f   fft p50 = %.1f",
                   NR, t[int(NR*0.05)+1], t[int(NR*0.5)], t[int(NR*0.95)],
                   e[int(NR*0.5)], f[int(NR*0.5)]
        }')

    local stalls
    stalls=$(grep -a RXTRACE "$log" \
        | sed -e 's/\[RXTRACE\] i=//' -e 's/ d_rx=/ /' -e 's/ age=.*//' \
        | awk '$2 > 500 {n++} END {printf "%d", n+0}')

    local gapmax
    gapmax=$(grep -a RXTRACE "$log" \
        | sed -e 's/.*d_rx=//' -e 's/ .*//' \
        | sort -n | tail -1)

    printf '%-10s exit=%d  %s\n' "$tag" "$ex" "$stats"
    printf '%-10s stalls over 500us in first 600 arrivals: %s   longest gap: %s us\n\n' \
           "" "$stalls" "$gapmax"
}

echo "samples=$SAMPLES pace=${PACE}us n=$N warmup=$W"
echo
run sleeping
run spinning --rx-spin
