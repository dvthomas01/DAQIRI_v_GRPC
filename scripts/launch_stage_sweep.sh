#!/bin/sh
# Detached launcher. Exists only because PowerShell mangles & and embedded
# quotes on the way through ssh, so the whole command has to live in a file.
# Guards against a double launch, which would put two sweeps on the GPU at once
# and quietly corrupt both. Match the bash invocation specifically: a looser
# pattern also matches this launcher's own name and refuses to start.
if pgrep -af 'bash scripts/[s]tage_sweep.sh' >/dev/null 2>&1; then
    echo "ALREADY RUNNING:"; pgrep -af 'bash scripts/[s]tage_sweep.sh'; exit 1
fi
cd "$HOME/daqiri_gpu" || exit 1
setsid nohup env \
    SIZES="1048576 4096" \
    ARMS="base opt daq extbuf" \
    REPS=3 N=1000 W=500 PACE=25 \
    OUT=data/stage_runs.csv LOGDIR=/tmp/stage \
    GITSHA=69cfd86+stagetimers \
    bash scripts/stage_sweep.sh > /tmp/stage_run.log 2>&1 < /dev/null &
echo "LAUNCHED pid=$!"
