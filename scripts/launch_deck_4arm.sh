#!/bin/sh
# Launch the four-arm 4 MiB deck sweep detached, so an ssh drop cannot kill it.
#
# The environment lives in this file rather than on an ssh command line because
# PowerShell 5.1 strips embedded double quotes, so MODES="sat unsat" arrives at
# the remote shell as two words and `unsat` is run as a command.
#
# SMOKE=1 runs a single short rep of every arm in both modes to prove the four
# invocations still work, and writes somewhere harmless.
set -u
cd "$HOME/daqiri_gpu" || exit 1

if pgrep -f 'bash scripts/deck_4arm_4mib.sh' > /dev/null 2>&1; then
    echo "ABORT: a deck_4arm_4mib.sh run is already active"
    exit 1
fi

SMOKE="${SMOKE:-0}"
SHA="${SHA:-75b6871+deck}"

if [ "$SMOKE" = "1" ]; then
    REPS=1; NMSG=150; WARM=50
    OUTF=/tmp/d4_smoke.csv; LOGD=/tmp/d4smoke; TAG=smoke
    LOGF=/tmp/d4_smoke.log
else
    REPS=12; NMSG=1000; WARM=500
    OUTF=data/deck_4arm_4mib.csv; LOGD=/tmp/deck4; TAG="$SHA"
    LOGF=/tmp/deck_4arm_4mib.log
fi

setsid env \
    GITSHA="$TAG" \
    REPS="$REPS" \
    N="$NMSG" \
    W="$WARM" \
    MODES="sat unsat" \
    OUT="$OUTF" \
    LOGDIR="$LOGD" \
    bash scripts/deck_4arm_4mib.sh >> "$LOGF" 2>&1 < /dev/null &

echo "launched, pid $!"
echo "log: $LOGF"
echo "out: $OUTF"
