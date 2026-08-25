#!/usr/bin/env bash
# Smoke test BEFORE committing to a profiling plan.
# Two questions:
#   A. Does nsys CUDA tracing work as a non-root user? (expected yes, CUPTI
#      activity tracing is not gated by RmProfilingAdminOnly)
#   B. Does ncu work? (expected NO, RmProfilingAdminOnly=1 blocks HW counters)
# Also checks that nsys survives the daq binary's _exit(), which skips atexit
# handlers and could eat the report.
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
cd "$HOME/daqiri_gpu" || exit 1
mkdir -p /tmp/prof
rm -f /tmp/prof/smoke*

echo "=== A. nsys, tiny daq run (16 KB, 40 buffers) ==="
timeout 180 nsys profile \
    --trace=cuda,nvtx,osrt \
    --sample=none --cpuctxsw=none \
    --force-overwrite=true \
    --output=/tmp/prof/smoke_daq \
    ./build/daqiri/bench_daqiri_roce_pipeline \
      --yaml daqiri/config_roce_pipeline.yaml --bufsize 4096 \
      --n-buffers 40 --warmup 20 --pace-us 100 --zero-copy \
      --out /tmp/prof/smoke.csv > /tmp/prof/smoke_daq.log 2>&1
echo "nsys exit=$?"
echo "--- last lines of log ---"
tail -6 /tmp/prof/smoke_daq.log
echo "--- report file? ---"
ls -l /tmp/prof/smoke_daq.nsys-rep 2>&1

echo
echo "=== A2. can we turn the report into text? ==="
if [ -f /tmp/prof/smoke_daq.nsys-rep ]; then
    nsys stats --report cuda_gpu_kern_sum --format table \
        /tmp/prof/smoke_daq.nsys-rep 2>&1 | head -20
fi

echo
echo "=== B. ncu, expected to be blocked ==="
timeout 120 ncu --version >/dev/null 2>&1
timeout 180 ncu --metrics sm__cycles_elapsed.avg --launch-count 1 --target-processes all \
    ./build/daqiri/bench_daqiri_roce_pipeline \
      --yaml daqiri/config_roce_pipeline.yaml --bufsize 4096 \
      --n-buffers 20 --warmup 10 --pace-us 100 --zero-copy \
      --out /tmp/prof/smoke2.csv 2>&1 | grep -a -e ERR_NVGPUCTRPERM -e "permission" -e "Profiling is not" -e "==PROF==" -e "sm__cycles" | head -8
echo "ncu pipeline done"

echo
echo "=== cleanup check ==="
pgrep -af '[b]ench_daqiri' || echo "  no stragglers"
