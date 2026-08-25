#!/bin/sh
# Detached launcher for the settle sweep. PowerShell 5.1 mangles quotes and &
# out of an ssh command line, so the metacharacters stay on the Spark side.
set -u
cd "$HOME/daqiri_gpu" || exit 1
if pgrep -f 'bash scripts/[s]ettle_sweep.sh' >/dev/null 2>&1; then
    echo "ALREADY RUNNING"; exit 1
fi
export GITSHA="${GITSHA:-035d8e8+pre}"
export REPS="${REPS:-10}"
: > /tmp/settle_run.log
setsid bash scripts/settle_sweep.sh >> /tmp/settle_run.log 2>&1 < /dev/null &
sleep 1
echo "LAUNCHED pid=$(pgrep -f 'bash scripts/[s]ettle_sweep.sh' | head -1)"
