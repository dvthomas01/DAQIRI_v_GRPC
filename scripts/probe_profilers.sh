#!/usr/bin/env bash
# Probe: what profiling tooling is actually usable on this box, as this user?
# Answers three questions, in order of how likely they are to block us:
#   1. Do nsys / ncu exist at all?
#   2. Does the driver let a non-root user read GPU hardware counters?
#   3. Are the binaries we need to profile present and runnable?
# Prints one fact per line. Nothing here runs a benchmark.
export PATH=/usr/local/cuda-13/bin:/usr/local/cuda/bin:/usr/bin:/bin
cd "$HOME/daqiri_gpu" 2>/dev/null || { echo "NO_REPO"; exit 1; }

echo "=== 1. tools on PATH ==="
for t in nsys ncu nvprof compute-sanitizer; do
    p=$(command -v $t 2>/dev/null)
    if [ -n "$p" ]; then
        echo "$t : $p"
    else
        echo "$t : MISSING"
    fi
done
echo
echo "--- also look where CUDA installs them, in case PATH is the only problem ---"
ls -1 /usr/local/cuda*/bin/ns* /usr/local/cuda*/bin/nc* 2>/dev/null | head -20
ls -1d /opt/nvidia/nsight* /opt/nvidia/nsight-systems/* 2>/dev/null | head -10
echo
echo "=== 2. versions ==="
nsys --version 2>&1 | head -3
ncu --version 2>&1 | head -4
echo
echo "=== 3. counter permission (this is the usual blocker) ==="
# RmProfilingAdminOnly=1 means only root may read HW perf counters.
# nsys CUDA *tracing* (CUPTI activity) is unaffected; ncu and nsys --gpu-metrics are.
if [ -r /proc/driver/nvidia/params ]; then
    grep -a -e RmProfilingAdminOnly -e RestrictProfiling /proc/driver/nvidia/params || echo "no RmProfilingAdminOnly line"
else
    echo "/proc/driver/nvidia/params NOT READABLE"
fi
echo "modprobe.d entries:"
grep -rasn -e NVreg_RestrictProfilingToAdminUsers /etc/modprobe.d/ 2>/dev/null || echo "  none"
echo "sudo -n: $(sudo -n true 2>&1 && echo YES || echo NO)"
echo
echo "=== 4. binaries we would profile ==="
for b in build/daqiri/bench_daqiri_roce_pipeline build_grpc/bench_grpc_server \
         build_grpc/bench_grpc_client /tmp/extbuf_fft_server /tmp/extbuf_fft_client; do
    if [ -x "$b" ]; then
        echo "OK   $b  ($(stat -c '%y' "$b" | cut -d. -f1))"
    else
        echo "MISS $b"
    fi
done
echo
echo "=== 5. GPU + clock state ==="
nvidia-smi --query-gpu=name,clocks.sm,clocks.max.sm,temperature.gpu --format=csv,noheader 2>&1
echo
echo "=== 6. is anything already running that would perturb a measurement? ==="
pgrep -af '[b]ench_|[e]xtbuf_|[h]eadline_sweep' || echo "  clear"
