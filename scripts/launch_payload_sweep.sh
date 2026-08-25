#!/usr/bin/env bash
# Detached launcher: both passes of the payload sweep, back to back.
#
# TWO PASSES, BECAUSE ONE PACING SETTING CANNOT ANSWER BOTH HALVES OF THE
# QUESTION.
#
# Pass A, fixed 25 us. This is the regime every earlier table in this project
# used, so its e2e and FFT columns can be read next to them. Two of the three
# arms are over-driven at this pace: the gRPC shared-memory ring drops messages
# and the DAQiri sender builds a queue, so pass A's transport column is a
# saturation measurement rather than a latency.
#
# Pass B, size-derived pace holding the offered rate at 1 GB/s. Nobody
# saturates, so transport means one-way latency in all three arms. The cost is
# that the FFT column moves: the RDMA arm is known to get slower as pacing
# increases, so its pass B transform time is not comparable to pass A's.
#
# Neither pass answers on its own. Read transport from B and the transform from
# A, and treat the difference between the two e2e columns as the pacing effect.
set -u
cd "$HOME/daqiri_gpu" || exit 1

if pgrep -f 'bash scripts/payload_sweep.sh' >/dev/null 2>&1; then
    echo "ALREADY RUNNING"; exit 1
fi

: > /tmp/payload_sweep.log
cat > /tmp/payload_both.sh <<'EOS'
set -u
cd "$HOME/daqiri_gpu" || exit 1
echo "######## PASS A: fixed pace 25 us ########"
PACE_MODE=fixed PACE=25 \
  OUT=data/payload_runs_paced25.csv LOGDIR=/tmp/payload_a \
  bash scripts/payload_sweep.sh
echo "######## PASS B: 1 GB/s offered ########"
PACE_MODE=rate \
  OUT=data/payload_runs_unsaturated.csv LOGDIR=/tmp/payload_b \
  bash scripts/payload_sweep.sh
echo "######## BOTH PASSES DONE ########"
EOS

setsid env \
    GITSHA="${GITSHA:-b3d5807+ts}" \
    SIZES="${SIZES:-4096 16384 65536 262144 1048576}" \
    ARMS="${ARMS:-opt extbuf daq}" \
    REPS="${REPS:-6}" \
    bash /tmp/payload_both.sh >> /tmp/payload_sweep.log 2>&1 < /dev/null &
sleep 2
echo "launched, pid $(pgrep -f 'bash scripts/payload_sweep.sh' | head -1)"
