#!/usr/bin/env bash
# Decide what DAQiri's large transport figure actually is.
#
# The age of one message cannot tell these apart:
#   (a) the receiver is behind, so messages queue and each waits its turn
#   (b) messages really do surface to the application in bursts
# The arrival trace can. d_rx is the gap between this arrival and the previous
# one, ahead is how many later messages the sender had already handed to the NIC
# at that moment.
#
#   (a) backlog  -> ahead grows large, d_rx settles near the receiver's service
#                   time (well under the send interval)
#   (b) bursts   -> d_rx collapses to ~0 for a run, then one big gap, while
#                   ahead stays small
#   (c) neither  -> d_rx tracks the send interval and age is roughly constant,
#                   which would mean the transport figure is real one-way time
#
# Usage: bash scripts/trace_daqiri_rx.sh [samples] [pace_us] [n] [warmup]
set -u
cd "$HOME/daqiri_gpu" || exit 1

SAMPLES=${1:-65536}
PACE=${2:-500}
N=${3:-200}
W=${4:-50}
TRACE=${TRACE:-60}
BIN=build/daqiri/bench_daqiri_roce_pipeline
LOG=/tmp/daq_trace.log

pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
sleep 1

timeout 240 "$BIN" \
    --yaml daqiri/config_roce_pipeline.yaml \
    --bufsize "$SAMPLES" --n-buffers "$N" --warmup "$W" \
    --pace-us "$PACE" --zero-copy --trace-rx "$TRACE" \
    --out /tmp/daq_trace.csv > "$LOG" 2>&1
echo "run exit=$?  samples=$SAMPLES pace=${PACE}us n=$N warmup=$W"

echo "---- arrival trace (d_rx = gap since previous arrival) ----"
grep -a RXTRACE "$LOG" | head -"$TRACE"

echo "---- d_rx distribution over the traced arrivals ----"
grep -a RXTRACE "$LOG" \
  | sed -e 's/.*d_rx=//' -e 's/ .*//' \
  | sort -n \
  | awk '{v[NR]=$1} END{
      if(NR<4){print "  too few"; exit}
      printf "  n=%d  min=%.1f  p50=%.1f  p90=%.1f  max=%.1f\n",
             NR, v[1], v[int(NR*0.5)], v[int(NR*0.9)], v[NR]}'

echo "---- max ahead over the traced arrivals ----"
grep -a RXTRACE "$LOG" \
  | sed -e 's/.*ahead=//' \
  | sort -n | tail -1 | awk '{printf "  max ahead = %s messages\n", $1}'

# Where the stalls sit in the run. The receive-buffer pool holds num_bufs
# distinct addresses, and the zero-copy path pays a CUDA registration the first
# time it sees each one. If the stalls stop once every buffer has been seen, the
# stall is that registration and has nothing to do with the transport.
echo "---- arrivals preceded by a gap over 500 us (index: gap) ----"
grep -a RXTRACE "$LOG" \
  | sed -e 's/\[RXTRACE\] i=//' -e 's/ d_rx=/ /' -e 's/ age=.*//' \
  | awk '$2 > 500 {printf "  i=%-5s gap=%.0f us\n", $1, $2; n++}
         END {printf "  %d stalls total\n", n+0}'

echo "---- stall rate by third of the trace ----"
grep -a RXTRACE "$LOG" \
  | sed -e 's/\[RXTRACE\] i=//' -e 's/ d_rx=/ /' -e 's/ age=.*//' \
  | awk '{i[NR]=$1; g[NR]=$2; last=$1}
         END {for (k=1;k<=NR;k++) { b=int(3*i[k]/(last+1)); c[b]++; if (g[k]>500) s[b]++ }
              for (b=0;b<3;b++) printf "  third %d: %d stalls in %d arrivals\n", b+1, s[b]+0, c[b]+0}'

echo "---- sender fill + any warnings ----"
grep -a fill "$LOG" | head -3
grep -a Sent "$LOG" | head -3
