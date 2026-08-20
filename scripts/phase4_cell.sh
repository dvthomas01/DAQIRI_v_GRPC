#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Phase 4 cell driver.  Runs on the Spark, drives the PXI over ssh.
#
# Four arms, rotated within every rep:
#
#   rdma               external buffers, our pool, event-gated re-queue
#   rdma-stock-nopoll  driver-allocated buffers, same fork, RX polling off
#   opt                gRPC-Direct shmem, optimizations on
#   base               gRPC-Direct shmem, optimizations off
#
# This exists rather than another headline_sweep.sh arm because two of the
# four arms need a process on the other machine. headline_sweep.sh runs
# entirely on the Spark and has no way to start the PXI client, so bolting the
# RDMA arms into it would mean rewriting its run loop anyway. The parts worth
# sharing, the clock gate and the peak-sampling, are reproduced here rather
# than sourced, because that script is a self-contained thing that other
# results already depend on and this driver should not be able to break it.
#
# What is deliberately different from headline_sweep.sh:
#
#   The warmup is inside the measured process, not before it. Nothing can
#   leave the GPU clocked up between processes: sampling clocks.sm once a
#   second gave 208 208 208 2405 2405 2405 2405 2457 2405 234 208 208, so it
#   ramps about three seconds into load and falls back within one second of
#   the load stopping. A separate warmup process therefore buys nothing for a
#   run that starts afterwards. Both the RDMA server and the base server take
#   a warmup count large enough that the ramp happens before the measured
#   section starts, computed from the size below.
#
#   Verification stays on. It sits outside the timed window, so it does not
#   enter e2e, but it does delay the slot re-queue and therefore the sender's
#   credit. That shows up in blocked-send time, which is reported separately
#   and never folded into latency. Both RDMA arms pay it identically.
#
# Usage:
#   NPTS=1048576 REPS=3 bash scripts/phase4_cell.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

cd "$(dirname "$0")/.."
ROOT="$PWD"

NPTS="${NPTS:-1048576}"                 # floats per message; 1048576 = 4 MiB
REPS="${REPS:-3}"
# Four arms, rotated within every rep.  `opt` was added on 2026-08-20 after the
# first 4 MB run showed `base` spending ~300 us of its ~660 us on a per-buffer
# device-to-device realign that `--no-zc-align` exists to disable.  Comparing a
# transport against an arm carrying a deliberately disabled optimization is not
# a transport comparison, so `opt` is the arm any transport claim gets made
# against and `base` stays only as the standing reference.
ARMS="${ARMS:-rdma rdma-stock-nopoll opt base}"
OUT="${OUT:-data/phase4_cell_${NPTS}.csv}"

PXI="${PXI:-admin@10.198.65.118}"       # management path, deliberately not the
                                        # RoCE link: control traffic must not
                                        # share the fabric being measured
SPARK_RDMA_IP="${SPARK_RDMA_IP:-192.168.20.1}"
PXI_RDMA_IP="${PXI_RDMA_IP:-192.168.20.2}"
RPORT="${RPORT:-18811}"
BPORT="${BPORT:-50111}"

RSRV="${RSRV:-/tmp/extbuf_fft_server}"
RCLI="${RCLI:-/home/admin/extbuf_p3/extbuf_fft_client}"
BSRV="${BSRV:-$ROOT/build_grpc/bench_grpc_server}"
BCLI="${BCLI:-$ROOT/build_grpc/bench_grpc_client}"

MIN_SM_MHZ="${MIN_SM_MHZ:-2400}"
SLOTS="${SLOTS:-4}"
PACE="${PACE:-0}"

BYTES=$((NPTS * 4))

# Warmup sizing.  Gate 3 measured 5843 MiB/s on this fabric with a 1.81 us
# floor, so one message costs bytes/6127 + 1.81 microseconds.  Ask for four
# seconds of traffic, which clears the three second ramp with margin.
WARM_MSGS="${WARM_MSGS:-$(awk -v b="$BYTES" 'BEGIN{
    per = b/6127.0 + 1.81; n = int(4000000.0/per) + 1;
    if (n > 1000000) n = 1000000; print n }')}"
MSGS="${MSGS:-1000}"

# The base arm has no wire, so its cost per buffer is the pacing interval or
# the transform, whichever is larger.  Size its warmup the same way against
# four seconds.
BWARM="${BWARM:-$(awk -v b="$BYTES" -v p="${BPACE:-400}" 'BEGIN{
    per = b/25000.0; if (per < 40) per = 40; if (p > per) per = p;
    n = int(4000000.0/per) + 1; if (n > 200000) n = 200000; print n }')}"
BMSGS="${BMSGS:-1000}"
BPACE="${BPACE:-400}"

# The shmem arm drops, and the server counts its warmup in buffers RECEIVED,
# not buffers sent. A first attempt sent unpaced and got 1252 of 4300 through,
# which is below the warmup threshold on its own, so the measured section never
# started and the cell reported nothing. Pacing fixes that: at 400 us delivery
# is about 99 percent at this size, against 29 percent unpaced.
#
# Note the asymmetry between the two programs, which cost a run to find. The
# client's --n-buffers is the measured count and its warmup is sent on top, so
# it puts BWARM + BSEND on the wire. The server's --n-buffers is the total it
# expects to see. A ten percent overshoot on the measured count covers the
# drops that remain; overshooting only ever yields extra measured buffers.
BSEND=$(( BMSGS + BMSGS / 10 + 10 ))

# The Spark copy of the tree is an scp mirror with no git metadata, so the SHA
# is normally passed in from the machine that has it. Falling back silently to
# "nogit" would put unattributable rows in the artifact, so it is recorded as
# such and visible in every row.
if [ -z "${GITSHA:-}" ]; then
    GITSHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"
    [ -n "$GITSHA" ] || GITSHA="nogit"
    if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
        GITSHA="${GITSHA}+dirty"
    fi
fi

# ── preflight ────────────────────────────────────────────────────────────────
fail () { echo "ABORT: $*" >&2; exit 1; }

for f in "$RSRV" "$BSRV" "$BCLI"; do
    [ -x "$f" ] || fail "missing binary $f"
done
if [ "$RSRV" -ot "$ROOT/rdma/extbuf_fft_server.cu" ]; then
    fail "$RSRV is older than rdma/extbuf_fft_server.cu. Rebuild before measuring."
fi
ssh -o BatchMode=yes -o ConnectTimeout=8 "$PXI" "test -x $RCLI" 2>/dev/null \
    || fail "cannot reach $PXI or $RCLI is missing"
ping -c 2 -W 2 "$PXI_RDMA_IP" >/dev/null 2>&1 \
    || fail "$PXI_RDMA_IP does not answer. The PXI reverts to a link-local address after a restart; run scripts/pxi_setip.sh."

# ── clock sampling ───────────────────────────────────────────────────────────
# Sampled for the duration of each run and reduced to the peak.  The peak and
# not the mean: the window contains process startup, plan creation and the
# unmeasured warmup, all of which are idle or partly idle by construction, and
# averaging them in gates out healthy cells.
CLK_PID=""
clk_start () {
    : > /tmp/p4_clk.txt
    ( while :; do
        nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null
        sleep 0.2
      done >> /tmp/p4_clk.txt ) &
    CLK_PID=$!
}
clk_peak () {
    [ -n "$CLK_PID" ] && kill "$CLK_PID" 2>/dev/null
    wait "$CLK_PID" 2>/dev/null
    CLK_PID=""
    grep -E '^[0-9]+$' /tmp/p4_clk.txt | sort -n | tail -1
}

cleanup () {
    pkill -9 -f extbuf_fft_server 2>/dev/null
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    ssh -o BatchMode=yes "$PXI" "pkill -9 -f extbuf_fft_client" >/dev/null 2>&1
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}
trap 'clk_peak >/dev/null 2>&1; cleanup' EXIT

# ── percentiles from the receiver CSV ────────────────────────────────────────
# p50 and p99 of e2e, p50 of the transform, count and verified count.
# The first data row is dropped: it is the first message after the warmup
# handoff and carries the cost of whatever the warmup left in flight.
# Sorting is done with sort(1) rather than awk's asort, which is a gawk
# extension and is not present in the awk on this box.
pct_from_csv () {
    local f="$1" n e50 e99 g50 v
    [ -s "$f" ] || { echo "NA NA NA 0 0"; return; }
    n=$(tail -n +3 "$f" | wc -l)
    if [ "${n:-0}" -lt 3 ]; then echo "NA NA NA 0 0"; return; fi
    e50=$(tail -n +3 "$f" | cut -d, -f5 | sort -g | awk -v n="$n" 'NR==int(n*0.50){print; exit}')
    e99=$(tail -n +3 "$f" | cut -d, -f5 | sort -g | awk -v n="$n" 'NR==int(n*0.99){print; exit}')
    g50=$(tail -n +3 "$f" | cut -d, -f6 | sort -g | awk -v n="$n" 'NR==int(n*0.50){print; exit}')
    v=$(tail -n +3 "$f" | cut -d, -f9 | grep -c '^1$')
    echo "$e50 $e99 $g50 $n $v"
}

# ── the arms ─────────────────────────────────────────────────────────────────
run_rdma () {                   # $1 = arm name, $2 = rep, $3 = extra server args
    local arm="$1" rep="$2" extra="$3"
    local mcsv="$ROOT/data/p4_${arm}_${NPTS}_${rep}.csv"
    local slog="/tmp/p4_${arm}_${NPTS}_${rep}.srv"
    local clog="/tmp/p4_${arm}_${NPTS}_${rep}.cli"
    rm -f "$mcsv"

    cleanup
    clk_start
    ( cd "$ROOT/rdma" && timeout 900 "$RSRV" \
        --addr "$SPARK_RDMA_IP" --port "$RPORT" --npts "$NPTS" \
        --warmup "$WARM_MSGS" --msgs "$MSGS" --slots "$SLOTS" \
        --poison off --verify every --tol-bins 2 \
        --csv "$mcsv" --sha "$GITSHA" $extra ) >"$slog" 2>&1 &
    local spid=$!
    sleep 3
    ssh -o BatchMode=yes "$PXI" \
        "cd /home/admin/extbuf_p3 && GRPC_DIRECT_RDMA_LOCAL=$PXI_RDMA_IP \
         timeout 900 ./extbuf_fft_client --host $SPARK_RDMA_IP --port $RPORT \
         --npts $NPTS --msgs $((WARM_MSGS + MSGS)) --warmup $WARM_MSGS \
         --pace-us 0 --linger-ms 400" >"$clog" 2>&1
    wait $spid 2>/dev/null
    SM=$(clk_peak)

    read -r e50 e99 f50 n vok <<<"$(pct_from_csv "$mcsv")"
    DELIV=$(grep -a '^sent  *:' "$clog" | head -1 | awk '{print $3}')
    ATTEMPT=$(grep -a '^sent  *:' "$clog" | head -1 | awk '{print $5}')
    SEND50=$(grep -a 'send call p50' "$clog" | awk '{print $5}')
    BLOCKED=$(grep -a 'blocked in send' "$clog" | awk '{print $5}')
    VERIF="$vok"
    N="$n"
    E50="$e50"; E99="$e99"; F50="$f50"
}

run_base () {                   # $1 = arm name, $2 = rep, $3 = extra server flags
    local arm="$1" rep="$2" xflags="$3"
    local bcsv="$ROOT/data/p4_${arm}_${NPTS}_${rep}.csv"
    local blog="/tmp/p4_${arm}_${NPTS}_${rep}.log"
    rm -f "$bcsv" "$blog"

    cleanup
    clk_start
    timeout 900 "$BSRV" --port "$BPORT" --bufsize "$BYTES" \
        --n-buffers $((BWARM + BSEND)) --warmup "$BWARM" --out "$bcsv" \
        --transport shmem --one-shot \
        --zero-copy $xflags >"$blog" 2>&1 &
    local spid=$!
    sleep 4
    timeout 600 taskset -c 11 "$BCLI" --server "localhost:$BPORT" \
        --transport shmem --bufsize "$BYTES" --n-buffers "$BSEND" \
        --warmup "$BWARM" --pace-us "$BPACE" >>"$blog" 2>&1
    wait $spid 2>/dev/null
    SM=$(clk_peak)

    N=$(grep -aoE 'n_measured=[0-9]+' "$blog" | head -1 | cut -d= -f2)
    E50=$(awk '/E2E p50/{print $4; exit}' "$blog")
    E99=$(awk '/E2E p50/{print $8; exit}' "$blog")
    F50=$(awk '/cuFFT p50/{print $4; exit}' "$blog")
    # The shmem arm drops rather than blocks, so delivered-of-attempted is the
    # figure that matters here and there is no blocked-send time to report.
    # Both come from the receiver's own delivery accounting, which counts the
    # sequence span the sender produced rather than what the harness asked for.
    DELIV=$(awk '/^  received/{print $3; exit}' "$blog")
    ATTEMPT=$(grep -aoE '\(span [0-9]+\)' "$blog" | head -1 | tr -dc '0-9')
    SEND50=NA; BLOCKED=NA; VERIF=NA
}

# ── go ───────────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/data"
echo "arm,npts,bytes,rep,e2e_p50,e2e_p99,fft_p50,resid,n,verified,delivered,attempted,send_p50,blocked_us,sm_mhz,result,gitsha" > "$OUT"

echo "phase 4 cell: ${BYTES} bytes (${NPTS} pts), $REPS reps, sha $GITSHA"
echo "  rdma warmup ${WARM_MSGS} msgs then ${MSGS} measured"
echo "  base warmup ${BWARM} bufs then ${BSEND} sent measured, pace ${BPACE} us"
echo
printf "%-18s %-4s %-9s %-9s %-9s %-8s %-6s %-9s %-8s %-7s %s\n" \
  "arm" "rep" "e2e_p50" "e2e_p99" "fft_p50" "resid" "n" "delivered" "send_p50" "sm_mhz" "result"
echo "-------------------------------------------------------------------------------------------------------"

set -- $ARMS
NARMS=$#
for R in $(seq 1 "$REPS"); do
  # Rotation, not interleaving.  Interleaving alone leaves every arm in the
  # same position within each rep, so anything that drifts with position
  # inside a rep, thermals most obviously, lands on the same arm every time
  # and is indistinguishable from an arm effect.
  ORDER=""
  for I in $(seq 0 $((NARMS - 1))); do
    K=$(( (I + R - 1) % NARMS + 1 ))
    ORDER="$ORDER $(eval echo \${$K})"
  done

  for ARM in $ORDER; do
    case "$ARM" in
      rdma)              run_rdma "$ARM" "$R" "" ;;
      rdma-stock-nopoll) run_rdma "$ARM" "$R" "--stock" ;;
      base)              run_base "$ARM" "$R" "--no-zc-align --no-opt-stream" ;;
      opt)               run_base "$ARM" "$R" "" ;;
      *) echo "unknown arm $ARM" >&2; continue ;;
    esac

    if [ -n "${E50:-}" ] && [ -n "${F50:-}" ] && [ "${E50}" != NA ]; then
      RESID=$(awk -v a="$E50" -v b="$F50" 'BEGIN{printf "%.2f", a-b}')
      RES=OK
    else
      RESID=NA; RES=NORESULT
    fi
    if [ -z "${SM:-}" ]; then
      RES=NOCLOCK
    elif [ "$SM" -lt "$MIN_SM_MHZ" ] && [ "$RES" = OK ]; then
      RES=CLOCKLOW
    fi
    # A message that arrived but failed its spectrum check invalidates the
    # latency for that arm, because the transform was then not of the data we
    # think it was.  Marked, not dropped.
    if [ "$VERIF" != NA ] && [ -n "${N:-}" ] && [ "${N:-0}" -gt 0 ] \
       && [ "${VERIF:-0}" -lt "${N:-0}" ] && [ "$RES" = OK ]; then
      RES=BADSPECTRUM
    fi

    printf "%-18s %-4s %-9s %-9s %-9s %-8s %-6s %-9s %-8s %-7s %s\n" \
      "$ARM" "$R" "${E50:-NA}" "${E99:-NA}" "${F50:-NA}" "$RESID" "${N:-NA}" \
      "${DELIV:-NA}/${ATTEMPT:-NA}" "${SEND50:-NA}" "${SM:-NA}" "$RES"
    echo "$ARM,$NPTS,$BYTES,$R,${E50:-NA},${E99:-NA},${F50:-NA},$RESID,${N:-NA},${VERIF:-NA},${DELIV:-NA},${ATTEMPT:-NA},${SEND50:-NA},${BLOCKED:-NA},${SM:-NA},$RES,$GITSHA" >> "$OUT"
  done
done

echo "-------------------------------------------------------------------------------------------------------"
echo "DONE_PHASE4_CELL -> $OUT"
