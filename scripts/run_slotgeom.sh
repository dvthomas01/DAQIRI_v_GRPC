#!/bin/sh
# Build and run the slot-geometry probe on the Spark. Kept as a script because
# the driving workstation is PowerShell 5.1 and mangles anything with quotes.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin

pkill -9 -f extbuf_fft 2>/dev/null
pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
sleep 1

nvcc -O2 -arch=native -std=c++17 -I. -Icommon -Ifft \
     rdma/slotgeom_probe.cu fft/cufft_executor.cu common/signal_gen.cc \
     -lcufft -o /tmp/slotgeom_probe || { echo "BUILD FAILED"; exit 1; }
echo "built"
echo

echo "=== own_stream=false (what both Table B arms actually ran) ==="
/tmp/slotgeom_probe --npts 1048576 --reps 5
echo
echo "=== own_stream=true (candidate 1, re-tested by measurement) ==="
/tmp/slotgeom_probe --npts 1048576 --reps 5 --own-stream
