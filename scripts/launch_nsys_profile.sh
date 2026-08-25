#!/usr/bin/env bash
# Launcher. Exists only because a backgrounded remote command sent inline over
# PowerShell holds the SSH channel and looks hung, and because PowerShell
# mangles '&'. Everything that needs an ampersand lives in a file.
cd "$HOME/daqiri_gpu" || exit 1
pgrep -af '[n]sys_pipeline_profile.sh' >/dev/null 2>&1 && { echo "ALREADY RUNNING"; exit 1; }
rm -f /tmp/pp_run.log
setsid nohup env \
    SIZES="1048576 4096" \
    ARMS="base opt daq extbuf" \
    REPS=3 N=200 W=50 PACE=25 \
    PROFDIR=/tmp/prof \
    OUT=data/nsys_overhead.csv \
    GITSHA=d6ee60f \
    bash scripts/nsys_pipeline_profile.sh > /tmp/pp_run.log 2>&1 < /dev/null &
disown
sleep 2
echo "LAUNCHED pid=$(pgrep -f '[n]sys_pipeline_profile.sh' | head -1)"
