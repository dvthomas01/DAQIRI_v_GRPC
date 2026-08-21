#!/bin/sh
# transport_cell.sh — measure the part of the pipeline that was never measured.
#
# WHY THIS EXISTS
# Every latency number this project has produced starts its clock after the data
# has landed.  phase4_cell.sh reports e2e_p50 of 72 us at 4 MB and that number is
# correct, but the same CSV records a sender blocked 2205 us per buffer, which is
# 3.2x the 685 us the fabric needs and puts the consumer at a 3% duty cycle.  The
# headline was a measurement of the idle end of a pipeline that spends its life
# waiting.
#
# Two instruments are added here, and they are instruments for different things.
# They are never in the same run and must never be in the same table row.
#
#   ECHO, on the sender's clock alone.  The PXI timestamps before it posts, the
#   Spark transforms and replies sixteen bytes, the PXI timestamps the reply.
#   This is post-to-transform-complete, which is the number a system integrator
#   asks for.  It is measured this way and not by differencing wall clocks
#   because the PXI's realtime clock is 23.13 seconds ahead of the Spark's,
#   measured by round trip on 2026-08-21, and neither box runs NTP or chrony.
#
#   Waiting for a reply serialises the sender, because grpc-direct's RDMA client
#   holds one pending response in a thread-local slot.  So echo measures UNLOADED
#   latency: one buffer at a time, no pipelining, no queueing.  That is the right
#   instrument for latency and a wrong one for throughput.
#
#   INTER-ARRIVAL, on the receiver's clock alone, from a streaming run.  How
#   often a buffer actually shows up, so it is the reciprocal of sustained rate
#   and it is what bounds the pipeline.
#
# THE CALIBRATION ARM
# The echo span contains the return path, so echo-cal measures the return path
# with nothing else in it: a tiny payload and --fft off on the receiver.  The
# headline is echo minus echo-cal.  That subtraction assumes the return leg costs
# the same in both runs, which holds because the ack is sixteen bytes on the same
# session in both.  It does not assume the request leg is symmetric, and it must
# not be read as if it did.
#
# Usage:
#   GITSHA=abc1234 sh scripts/transport_cell.sh
#   NPTS=4096 REPS=5 sh scripts/transport_cell.sh
#   SLOTS=8 OUT=data/transport_slots8.csv sh scripts/transport_cell.sh
#
# The slot-depth question is answered by running this repeatedly with different
# SLOTS and concatenating, rather than by sweeping inside one invocation, so that
# rotation stays honest within each cell.

set -u

cd "$(dirname "$0")/.."
ROOT="$PWD"

NPTS="${NPTS:-1048576}"                 # floats per message; 1048576 = 4 MiB
CAL_NPTS="${CAL_NPTS:-64}"              # calibration payload: 256 B, one frame
REPS="${REPS:-3}"
ARMS="${ARMS:-echo echo-cal stream}"
SLOTS="${SLOTS:-4}"
OUT="${OUT:-data/transport_cell_${NPTS}_s${SLOTS}.csv}"

PXI="${PXI:-admin@10.198.65.118}"       # management path, deliberately not the
                                        # RoCE link
SPARK_RDMA_IP="${SPARK_RDMA_IP:-192.168.20.1}"
PXI_RDMA_IP="${PXI_RDMA_IP:-192.168.20.2}"
RPORT="${RPORT:-18831}"

RSRV="${RSRV:-/tmp/extbuf_fft_server}"
RCLI="${RCLI:-/home/admin/extbuf_p3/extbuf_fft_client}"
RCLI_DIR="${RCLI_DIR:-/home/admin/extbuf_p3}"

MIN_SM_MHZ="${MIN_SM_MHZ:-2400}"
BYTES=$((NPTS * 4))

# Streaming warmup, same sizing as Phase 4: Gate 3 measured 5843 MiB/s with a
# 1.81 us floor, so one message costs bytes/6127 + 1.81 us.  Ask for four
# seconds, which clears the GB10's three second clock ramp with margin.
WARM_MSGS="${WARM_MSGS:-$(awk -v b="$BYTES" 'BEGIN{
    per = b/6127.0 + 1.81; n = int(4000000.0/per) + 1;
    if (n > 1000000) n = 1000000; print n }')}"
MSGS="${MSGS:-1000}"

# Echo warmup cannot use that formula.  Serialising the sender means one message
# costs roughly frame-build plus send plus wire plus transform plus return, which
# at 4 MB is milliseconds rather than microseconds, so the streaming count would
# ask for twenty seconds a rep.  Three milliseconds per message is the working
# estimate; the clock gate below is what actually decides whether it was enough,
# so getting this wrong is caught rather than silently absorbed.
ECHO_WARM="${ECHO_WARM:-$(awk 'BEGIN{ print int(4000000.0/3000.0) + 1 }')}"
ECHO_MSGS="${ECHO_MSGS:-300}"

# The calibration arm runs no transform, so the GPU clock is irrelevant to it and
# its warmup exists only to settle the fabric and the library's first-touch
# costs.
CAL_WARM="${CAL_WARM:-2000}"
CAL_MSGS="${CAL_MSGS:-2000}"

# The Spark copy of the tree is an scp mirror with no git metadata, so the SHA is
# normally passed in from the machine that has it.
if [ -z "${GITSHA:-}" ]; then
    GITSHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"
    [ -n "$GITSHA" ] || GITSHA="nogit"
    if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
        GITSHA="${GITSHA}+dirty"
    fi
fi

# ── preflight ────────────────────────────────────────────────────────────────
fail () { echo "ABORT: $*" >&2; exit 1; }

[ -x "$RSRV" ] || fail "missing binary $RSRV"
if [ "$RSRV" -ot "$ROOT/rdma/extbuf_fft_server.cu" ]; then
    fail "$RSRV is older than rdma/extbuf_fft_server.cu. Rebuild before measuring."
fi
ssh -o BatchMode=yes -o ConnectTimeout=8 "$PXI" "test -x $RCLI" 2>/dev/null \
    || fail "cannot reach $PXI or $RCLI is missing"
# The client is the half that changed most in this pass, so a stale one on the
# PXI would produce a run with no rtt column and no obvious reason why.
ssh -o BatchMode=yes "$PXI" "$RCLI --help 2>&1 | grep -q -- --echo" \
    || fail "$RCLI on the PXI has no --echo. Rebuild and copy it across."
# Same reasoning for --gen. A stale client silently ignores an unknown flag in
# some builds and would run copy mode while the CSV is labelled stream-inplace,
# which is the exact class of silent disagreement that cost us Phase 4.
case " $ARMS " in *\ stream-inplace\ *)
    ssh -o BatchMode=yes "$PXI" "$RCLI --help 2>&1 | grep -q -- --gen" \
        || fail "$RCLI on the PXI has no --gen, so stream-inplace would really be stream-nv. Rebuild and copy it across." ;;
esac
ping -c 2 -W 2 "$PXI_RDMA_IP" >/dev/null 2>&1 \
    || fail "$PXI_RDMA_IP does not answer. The PXI reverts to a link-local address after a restart; run scripts/pxi_setip.sh."

# ── clock sampling ───────────────────────────────────────────────────────────
CLK_PID=""
clk_start () {
    : > /tmp/tc_clk.txt
    ( while :; do
        nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null
        sleep 0.2
      done >> /tmp/tc_clk.txt ) &
    CLK_PID=$!
}
clk_peak () {
    [ -n "$CLK_PID" ] && kill "$CLK_PID" 2>/dev/null
    wait "$CLK_PID" 2>/dev/null
    CLK_PID=""
    grep -E '^[0-9]+$' /tmp/tc_clk.txt | sort -n | tail -1
}

cleanup () {
    pkill -9 -f extbuf_fft_server 2>/dev/null
    ssh -o BatchMode=yes "$PXI" "pkill -9 -f extbuf_fft_client" >/dev/null 2>&1
    sleep 1
}
trap 'clk_peak >/dev/null 2>&1; cleanup' EXIT

# ── percentiles from the receiver CSV ────────────────────────────────────────
# Columns: 1 seq, 2 slot, 3 bytes, 4 npts, 5 e2e_us, 6 fft_us, 7 peak_hz,
#          8 expect_hz, 9 ok, 10 gap_us, 11 gitsha.
# The first data row is dropped: it is the first message after the warmup
# handoff and carries the cost of whatever the warmup left in flight.
# sort(1) rather than awk's asort, which is a gawk extension not present here.
col_p50 () {                    # $1 = file, $2 = field, $3 = percentile
    local f="$1" c="$2" p="$3" n
    n=$(tail -n +3 "$f" | wc -l)
    [ "${n:-0}" -lt 3 ] && { echo NA; return; }
    tail -n +3 "$f" | cut -d, -f"$c" | sort -g \
        | awk -v n="$n" -v p="$p" 'NR==int(n*p){print; exit}'
}

# ── one run ──────────────────────────────────────────────────────────────────
# $1 arm, $2 rep, $3 npts, $4 server extra, $5 client extra, $6 warm, $7 msgs
run_one () {
    local arm="$1" rep="$2" np="$3" sx="$4" cx="$5" wm="$6" ms="$7"
    local scsv="$ROOT/data/tc_${arm}_${NPTS}_s${SLOTS}_${rep}.csv"
    local ccsv="/tmp/tc_${arm}_${NPTS}_s${SLOTS}_${rep}.cli.csv"
    local slog="/tmp/tc_${arm}_${NPTS}_s${SLOTS}_${rep}.srv"
    local clog="/tmp/tc_${arm}_${NPTS}_s${SLOTS}_${rep}.cli"
    rm -f "$scsv"

    cleanup
    clk_start
    ( cd "$ROOT/rdma" && timeout 1200 "$RSRV" \
        --addr "$SPARK_RDMA_IP" --port "$RPORT" --npts "$np" \
        --warmup "$wm" --msgs "$ms" --slots "$SLOTS" \
        --csv "$scsv" --sha "$GITSHA" $sx ) >"$slog" 2>&1 &
    local spid=$!
    sleep 3
    ssh -o BatchMode=yes "$PXI" \
        "cd $RCLI_DIR && GRPC_DIRECT_RDMA_LOCAL=$PXI_RDMA_IP \
         timeout 1200 ./extbuf_fft_client --host $SPARK_RDMA_IP --port $RPORT \
         --npts $np --msgs $((wm + ms)) --warmup $wm \
         --pace-us 0 --linger-ms 400 --csv $ccsv $cx" >"$clog" 2>&1
    wait $spid 2>/dev/null
    SM=$(clk_peak)

    # The sender's per-message CSV is the only place the frame-build and send
    # costs exist at full resolution, and the 2205 us question is a sender-side
    # question, so it comes back rather than staying on the PXI.
    scp -o BatchMode=yes -q "$PXI:$ccsv" \
        "$ROOT/data/$(basename "$ccsv")" 2>/dev/null || true

    E50=$(col_p50 "$scsv" 5 0.50)
    F50=$(col_p50 "$scsv" 6 0.50)
    G50=$(col_p50 "$scsv" 10 0.50)
    N=$(tail -n +3 "$scsv" 2>/dev/null | wc -l)
    VERIF=$(tail -n +3 "$scsv" 2>/dev/null | cut -d, -f9 | grep -c '^1$')

    RTT50=$(awk '/^echo rtt p50/{print $5; exit}' "$clog")
    RTT99=$(awk '/^echo rtt p50/{print $7; exit}' "$clog")
    GEN50=$(awk '/^frame build p50/{print $5; exit}' "$clog")
    SEND50=$(awk '/^send call p50/{print $5; exit}' "$clog")
    MIBS=$(awk '/^sustained rate/{print $4; exit}' "$slog")
    HOLD50=$(awk '/^credit return/{print $4; exit}' "$slog")
    RQ50=$(awk '/^credit return/{print $8; exit}' "$slog")
    BADACK=$(awk '/^bad acks/{print $4; exit}' "$clog")

    [ -n "${RTT50:-}" ] || RTT50=NA
    [ -n "${RTT99:-}" ] || RTT99=NA
    [ -n "${GEN50:-}" ] || GEN50=NA
    [ -n "${SEND50:-}" ] || SEND50=NA
    [ -n "${MIBS:-}" ]  || MIBS=NA
    [ -n "${HOLD50:-}" ] || HOLD50=NA
    [ -n "${RQ50:-}" ]  || RQ50=NA
    [ -n "${BADACK:-}" ] || BADACK=0
    [ -n "${G50:-}" ]   || G50=NA
}

# ── go ───────────────────────────────────────────────────────────────────────
mkdir -p "$ROOT/data"
echo "arm,npts,bytes,slots,rep,rtt_p50,rtt_p99,gen_p50,send_p50,e2e_p50,fft_p50,gap_p50,hold_p50,rq_p50,mib_s,n,verified,bad_ack,sm_mhz,result,gitsha" > "$OUT"

echo "transport cell: ${BYTES} bytes (${NPTS} pts), ${SLOTS} slots, $REPS reps, sha $GITSHA"
echo "  echo    warmup ${ECHO_WARM} then ${ECHO_MSGS} measured, serialised"
echo "  cal     ${CAL_NPTS} pts, warmup ${CAL_WARM} then ${CAL_MSGS} measured, no transform"
echo "  stream  warmup ${WARM_MSGS} then ${MSGS} measured"
echo
printf "%-10s %-4s %-10s %-9s %-9s %-9s %-9s %-8s %-7s %s\n" \
  "arm" "rep" "rtt_p50" "gen_p50" "send_p50" "e2e_p50" "gap_p50" "mib_s" "sm_mhz" "result"
echo "----------------------------------------------------------------------------------------------------"

set -- $ARMS
NARMS=$#
for R in $(seq 1 "$REPS"); do
  # Rotation, not interleaving.  Interleaving alone leaves every arm in the same
  # position within each rep, so anything that drifts with position inside a rep,
  # thermals most obviously, lands on the same arm every time and is
  # indistinguishable from an arm effect.
  ORDER=""
  for I in $(seq 0 $((NARMS - 1))); do
    K=$(( (I + R - 1) % NARMS + 1 ))
    ORDER="$ORDER $(eval echo \${$K})"
  done

  for ARM in $ORDER; do
    case "$ARM" in
      echo)
        run_one "$ARM" "$R" "$NPTS" \
          "--echo on --poison off --verify off" "--echo on" \
          "$ECHO_WARM" "$ECHO_MSGS" ;;
      echo-cal)
        run_one "$ARM" "$R" "$CAL_NPTS" \
          "--echo on --fft off --poison off --verify off" "--echo on" \
          "$CAL_WARM" "$CAL_MSGS" ;;
      stream)
        run_one "$ARM" "$R" "$NPTS" \
          "--poison off --verify every" "" \
          "$WARM_MSGS" "$MSGS" ;;
      stream-nv)
        # The same arm with the spectral check off, which is what the server's
        # own header said Phase 4 should have used and what Phase 4 did not do.
        #
        # HISTORICAL, and kept because the pairing is the evidence: detect_peaks
        # used to run after the gate and before slot_requeue, so its cost was
        # charged to the sender as credit it had not been given back, and this
        # arm was worth 3.18x against stream. The check has since moved below the
        # re-queue, so stream and stream-nv should now be one distribution. If
        # they are not, the server binary predates that change; check its --help.
        run_one "$ARM" "$R" "$NPTS" \
          "--poison off --verify off" "" \
          "$WARM_MSGS" "$MSGS" ;;
      stream-inplace)
        # The sender's own copy removed. Paired against stream-nv, which is the
        # same run with --gen copy, so the difference is one 4 MiB host memcpy
        # per message and nothing else. The receiver cannot tell the two apart.
        #
        # What it decides: with the receiver no longer holding credit, gen_p50
        # plus send_p50 accounted for essentially all of the inter-arrival, so
        # the sender is the bound. A real digitiser DMAs into the buffer it hands
        # to the transport and never does this copy, so if the rate moves here
        # then the receive path's share of link is limited by the harness.
        run_one "$ARM" "$R" "$NPTS" \
          "--poison off --verify off" "--gen inplace" \
          "$WARM_MSGS" "$MSGS" ;;
      *) echo "unknown arm $ARM" >&2; continue ;;
    esac

    RES=OK
    [ "${N:-0}" -ge 3 ] || RES=NORESULT
    if [ -z "${SM:-}" ]; then
      RES=NOCLOCK
    elif [ "$ARM" != "echo-cal" ] && [ "$SM" -lt "$MIN_SM_MHZ" ] && [ "$RES" = OK ]; then
      # echo-cal runs no transform, so its clock is irrelevant and gating on it
      # would fail every calibration run for a reason that cannot affect it.
      RES=CLOCKLOW
    fi
    # An ack that did not match its request means the round trip being timed is
    # not the one that was posted, which invalidates the latency rather than
    # merely flagging it.
    if [ "${BADACK:-0}" -ne 0 ] && [ "$RES" = OK ]; then RES=BADACK; fi
    # A message that arrived but failed its spectrum check invalidates the
    # latency for that arm, because the transform was then not of the data we
    # think it was.  Only the streaming arm verifies; echo trades the spectral
    # check for the ack's seq check, which the BADACK line above enforces.
    if [ "$ARM" = "stream" ] && [ "${N:-0}" -gt 0 ] \
       && [ "${VERIF:-0}" -lt "${N:-0}" ] && [ "$RES" = OK ]; then
      RES=BADSPECTRUM
    fi

    printf "%-10s %-4s %-10s %-9s %-9s %-9s %-9s %-8s %-7s %s\n" \
      "$ARM" "$R" "${RTT50}" "${GEN50}" "${SEND50}" "${E50}" "${G50}" \
      "${MIBS}" "${SM:-NA}" "$RES"
    echo "$ARM,$NPTS,$BYTES,$SLOTS,$R,$RTT50,$RTT99,$GEN50,$SEND50,$E50,$F50,$G50,$HOLD50,$RQ50,$MIBS,$N,$VERIF,$BADACK,${SM:-NA},$RES,$GITSHA" >> "$OUT"
  done
done

echo
echo "wrote $OUT"
echo
echo "The headline is echo rtt p50 minus echo-cal rtt p50, per rep, paired."
echo "Do not put a gap_p50 from the stream arm and an rtt_p50 from the echo arm"
echo "in the same sentence without saying they came from different runs."
