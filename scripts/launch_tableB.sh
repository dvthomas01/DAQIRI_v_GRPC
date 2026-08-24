#!/bin/sh
# Detached launcher for the Table B sweep.
#
# This exists because the workstation driving these runs is PowerShell 5.1,
# which strips embedded double quotes and mangles `&` out of an ssh command
# line.  Two launches have already been lost to that: one sat alive for fifteen
# minutes doing nothing.  Keeping every metacharacter on this side of the ssh
# means the command sent over the wire is a bare `sh scripts/launch_tableB.sh`
# with nothing in it for PowerShell to rewrite.
set -u
cd "$HOME/daqiri_gpu" || exit 1

pkill -9 -f headline_sweep 2>/dev/null
pkill -9 -f extbuf_fft 2>/dev/null
pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
pkill -9 -f bench_grpc 2>/dev/null
sleep 1

: > /tmp/tableB.log
setsid nohup sh scripts/run_tableB.sh >> /tmp/tableB.log 2>&1 < /dev/null &
sleep 3
echo "LAUNCHED pid=$!"
cat /tmp/tableB.log
