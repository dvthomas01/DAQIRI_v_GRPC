#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# size_sweep.sh — turn the 4 MiB transport result into a curve
#
# RUNS ON THE SPARK.  It ssh's to the PXI for the client, via transport_cell.sh,
# which does the actual work.  This file is only a driver: it picks the sizes,
# scales the message counts so every cell measures for a comparable wall-clock
# time rather than a comparable message count, and merges the per-size CSVs into
# one table with the theoretical wire time alongside each row.
#
# WHY A DRIVER AND NOT A LOOP INSIDE transport_cell.sh
# transport_cell.sh rotates arms within each rep so that position inside a rep
# cannot masquerade as an arm effect.  That rotation is only honest within one
# cell.  Sweeping sizes inside it would put size and position in the same
# rotation and confound them, so each size gets its own invocation and the
# results are concatenated afterwards.  The script's own header says so.
#
# WHAT IS AND IS NOT IN HERE
# The arms are the cross-machine ones: PXI posts, Spark receives, transforms and
# (for the echo arms) acks.  base and opt are NOT here.  They run
# bench_grpc_server --transport shmem against localhost, entirely on the Spark,
# with no PXI and no wire, and --zc-align is a shmem-loan concept with no RDMA
# counterpart.  Putting them in this table would be loopback against wire, which
# this project has already published twice and retracted twice.  Run them
# separately with scripts/phase4_cell.sh and label the table for what it is.
#
# TWO PASSES, DELIBERATELY
#   timed pass       --verify off.  Produces the rate and latency columns.
#   correctness pass --verify every.  Produces verified counts.  The server
#                    WITHHOLDS its rate under that flag, so this pass reports
#                    mib_s NA by design, not by failure.  handoff.md 7i is what
#                    happens when the two passes are the same pass.
#
# Usage, from ~/daqiri_gpu on the Spark:
#   GITSHA=abc1234 bash scripts/size_sweep.sh
#   SIZES="4096 16384" REPS=3 bash scripts/size_sweep.sh
#   REPS=5 bash scripts/size_sweep.sh
#
# Uses `local`, so run it with bash, not sh.
# ─────────────────────────────────────────────────────────────────────────────

set -u

cd "$(dirname "$0")/.."
ROOT="$PWD"

# Payload bytes.  4 KB and 16 KB sit where per-message overhead should dominate,
# 4 MiB is where bandwidth does, and 256 KB and 1 MiB bracket the crossover.
# npts = bytes/4, and every one of these is a power of two, which cuFFT wants.
SIZES="${SIZES:-4096 16384 262144 1048576 4194304}"
REPS="${REPS:-3}"
SLOTS="${SLOTS:-4}"
MIN_SM_MHZ="${MIN_SM_MHZ:-2400}"

# Tag goes in every per-cell filename.  Without it a second sweep with different
# arms silently overwrites the first sweep's cells, and the merged table is the
# only surviving copy of numbers that took an hour to take.
TAG="${TAG:-s${SLOTS}}"
OUT="${OUT:-data/size_sweep_${TAG}.csv}"

TIMED_ARMS="${TIMED_ARMS:-echo echo-cal stream-nv stream-inplace}"
# No colon: an explicitly empty VERIFY_ARMS must stay empty and skip the pass,
# whereas ${VERIFY_ARMS:-stream} would treat empty as unset and run it anyway.
VERIFY_ARMS="${VERIFY_ARMS-stream}"

if [ -z "${GITSHA:-}" ]; then
    GITSHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"
    [ -n "$GITSHA" ] || GITSHA="nogit"
fi

fail () { echo "ABORT: $*" >&2; exit 1; }
[ -f "$ROOT/scripts/transport_cell.sh" ] || fail "no scripts/transport_cell.sh"

# ── per-size message counts ──────────────────────────────────────────────────
# Gate 3 measured 5843 MiB/s with a 1.81 us floor, so one streamed message costs
# bytes/6127 + 1.81 us.  That is also the theoretical wire time this sweep
# reports each measured gap against.
wire_us () { awk -v b="$1" 'BEGIN{ printf "%.3f", b/6127.0 + 1.81 }'; }

# Streaming warmup: four seconds, which clears the GB10's three second clock
# ramp with margin.  Capped, because at 4 KB four seconds is 1.6 million
# messages and the cap is what keeps the sweep inside a sitting.
warm_for () {
    awk -v b="$1" 'BEGIN{
        per = b/6127.0 + 1.81; n = int(4000000.0/per) + 1;
        if (n > 1600000) n = 1600000; print n }'
}

# Measured count: aim for a fixed measurement DURATION rather than a fixed
# message count.  1000 messages is two thirds of a second at 4 MiB and two and a
# half MILLISECONDS at 4 KB, which is not a measurement, it is a sample of one
# scheduling quantum.  Half a second at every size, floored at 1000 so the big
# sizes keep the count the existing 4 MiB results used, and capped at 200k so
# the CSV stays inside the server's 64 MB row buffer and never flushes mid-run.
msgs_for () {
    awk -v b="$1" 'BEGIN{
        per = b/6127.0 + 1.81; n = int(500000.0/per) + 1;
        if (n < 1000)   n = 1000;
        if (n > 200000) n = 200000; print n }'
}

# Echo warmup cannot use the streaming formula: serialising the sender makes one
# message cost roughly two wire times plus the fixed request-and-return path.
# The fixed part is measured, not guessed: at 4 MiB this predicts 2*685 + 30 =
# 1400 us against a measured rtt_p50 of 1379 to 1438.  Four seconds of that.
echo_warm_for () {
    awk -v b="$1" 'BEGIN{
        per = 2.0*(b/6127.0 + 1.81) + 30.0; n = int(4000000.0/per) + 1;
        if (n > 200000) n = 200000; print n }'
}
echo_msgs_for () {
    awk -v b="$1" 'BEGIN{
        per = 2.0*(b/6127.0 + 1.81) + 30.0; n = int(500000.0/per) + 1;
        if (n < 300)   n = 300;
        if (n > 20000) n = 20000; print n }'
}

# ── run ──────────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/data"
STAMP=$(date +%Y%m%d_%H%M%S)
LOG="/tmp/size_sweep_${STAMP}.log"
CELLS=""

echo "size sweep: sha $GITSHA, $REPS reps, $SLOTS slots"
echo "sizes: $SIZES"
echo "log:   $LOG"
echo

for B in $SIZES; do
    NPTS=$((B / 4))
    W=$(wire_us "$B")
    WARM=$(warm_for "$B")
    MSG=$(msgs_for "$B")
    EWARM=$(echo_warm_for "$B")
    EMSG=$(echo_msgs_for "$B")

    echo "=============================================================="
    echo "  ${B} bytes (${NPTS} pts), wire ${W} us"
    echo "  timed:  warm ${WARM} then ${MSG} measured"
    echo "  echo:   warm ${EWARM} then ${EMSG} measured"
    echo "=============================================================="

    TOUT="data/ss_timed_${B}_${TAG}.csv"
    GITSHA="$GITSHA" REPS="$REPS" NPTS="$NPTS" SLOTS="$SLOTS" \
    WARM_MSGS="$WARM" MSGS="$MSG" ECHO_WARM="$EWARM" ECHO_MSGS="$EMSG" \
    MIN_SM_MHZ="$MIN_SM_MHZ" ARMS="$TIMED_ARMS" OUT="$TOUT" \
        bash scripts/transport_cell.sh 2>&1 | tee -a "$LOG"
    [ -f "$ROOT/$TOUT" ] && CELLS="$CELLS $TOUT"

    # Correctness, one rep, short.  Whether the spectrum is right is a boolean,
    # not a distribution, so it does not need three reps.  Its rate comes back
    # NA because the server withholds it under --verify every; that is the
    # guard working, not the cell failing.
    #
    # Skippable.  The loopback sweep re-runs this driver with one timed arm and
    # no verify arm, because its correctness was already established by the
    # cross-machine verify pass at the same sizes: the spectrum does not depend
    # on which box posted the buffer.  An empty ARMS would make transport_cell
    # write a header and no rows, so skip the invocation rather than pass it.
    if [ -n "$VERIFY_ARMS" ]; then
        VOUT="data/ss_verify_${B}_${TAG}.csv"
        GITSHA="$GITSHA" REPS=1 NPTS="$NPTS" SLOTS="$SLOTS" \
        WARM_MSGS="$WARM" MSGS="$MSG" \
        MIN_SM_MHZ="$MIN_SM_MHZ" ARMS="$VERIFY_ARMS" OUT="$VOUT" \
            bash scripts/transport_cell.sh 2>&1 | tee -a "$LOG"
        [ -f "$ROOT/$VOUT" ] && CELLS="$CELLS $VOUT"
    fi
done

# ── merge ────────────────────────────────────────────────────────────────────
# One table with three derived columns appended to every row:
#   resid    = e2e_p50 - fft_p50, the post-arrival time that is not the
#              transform. Reported because a residual that grows with size means
#              something other than the FFT is scaling.
#   wire_us  = bytes/6127 + 1.81, the Gate 3 model.
#   pct_wire = wire_us / gap_p50, so 100 means the pipeline is running at the
#              wire. At 4 MiB that is what established line rate; at 4 KB it is
#              where the claim should stop holding, which is the point.
#
# Field positions, from transport_cell.sh's header:
#   1 arm  2 npts  3 bytes  4 slots  5 rep  6 rtt_p50  7 rtt_p99  8 gen_p50
#   9 send_p50  10 e2e_p50  11 fft_p50  12 gap_p50  13 hold_p50  14 rq_p50
#   15 mib_s  16 n  17 verified  18 bad_ack  19 sm_mhz  20 result  21 gitsha
FIRST=$(echo $CELLS | awk '{print $1}')
[ -n "$FIRST" ] || fail "no cells produced any output; see $LOG"

{
  head -1 "$ROOT/$FIRST" | sed 's/$/,resid,wire_us,pct_wire,pct_wire_mean/'
  for C in $CELLS; do
    tail -n +2 "$ROOT/$C"
  done | awk -F, -v OFS=, '
    function num(x) { return (x=="NA" || x=="" ) ? -1 : x+0 }
    {
      e = num($10); f = num($11); g = num($12); b = num($3); gm = num($22);
      resid = (e<0 || f<0) ? "NA" : sprintf("%.2f", e-f);
      wire  = (b<0)        ? "NA" : sprintf("%.3f", b/6127.0 + 1.81);
      # The echo arms serialise the sender: it posts, waits for the ack, then
      # posts again, so their inter-arrival is a measure of the round trip and
      # comparing it to a wire time would say the fabric is 10% utilised when
      # nothing is wrong. Withheld. echo-cal is worse, because its bytes column
      # carries the cell size while the arm actually sent 64 points.
      pct = (g<=0 || b<0 || $1 ~ /^echo/) ? "NA" \
            : sprintf("%.1f", 100.0*(b/6127.0+1.81)/g);
      # Against the MEAN gap, which is the one that corresponds to bytes over
      # elapsed time. Read this column, not the one before it. pct_wire is the
      # cadence while the pipeline is streaming smoothly; pct_wire_mean includes
      # the stalls, and below 4 MiB the two differ by up to 5x because the
      # cadence is punctuated rather than steady. Section 7m.
      pctm = (gm<=0 || b<0 || $1 ~ /^echo/) ? "NA" \
            : sprintf("%.1f", 100.0*(b/6127.0+1.81)/gm);
      print $0, resid, wire, pct, pctm;
    }'
} > "$ROOT/$OUT"

echo
echo "merged -> $OUT"
echo "cells:$CELLS"
echo
echo "pct_wire is theoretical wire time over measured inter-arrival, so 100"
echo "means the pipeline is running at the wire and lower means it is not."
echo "gap_p50 and the echo rtt come from DIFFERENT runs: echo serialises the"
echo "sender. Do not put them in the same sentence without saying so."
