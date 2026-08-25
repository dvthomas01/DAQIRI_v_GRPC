#!/usr/bin/env bash
# Detach the extbuf --own-stream A/B so an ssh drop cannot kill it.
set -u
cd "$HOME/daqiri_gpu" || exit 1

if pgrep -f 'bash scripts/extbuf_stream_ab.sh' >/dev/null 2>&1; then
    echo "already running:"; pgrep -af 'bash scripts/extbuf_stream_ab.sh'; exit 1
fi

LOG=/tmp/extbuf_stream_ab.log
: > "$LOG"

setsid env \
    GITSHA=6688440+stream \
    SIZES="4096 262144 1048576" \
    REPS=8 N=1000 W=500 \
    OUT=data/extbuf_stream_ab.csv \
    LOGDIR=/tmp/exstream \
    bash scripts/extbuf_stream_ab.sh >> "$LOG" 2>&1 < /dev/null &

sleep 2
echo "launched, pid $(pgrep -f 'bash scripts/extbuf_stream_ab.sh' | head -1)"
echo "log: $LOG"
