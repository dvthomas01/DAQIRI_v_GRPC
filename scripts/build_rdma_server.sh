#!/usr/bin/env bash
# Compile-only check for the Phase 2 receiver after the GID-selection change.
set -u
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
cd "$HOME/daqiri_gpu/rdma" || exit 1
echo "### building rdma_fft_server ###"
nvcc -O2 -arch=native -std=c++17 -I. -I../common -I../fft \
     -o /tmp/rdma_fft_server rdma_fft_server.cu ../fft/cufft_executor.cu \
     ../common/signal_gen.cc \
     -libverbs -lcufft -Xcompiler -pthread 2>&1 | tail -40
echo "BUILD_EXIT=${PIPESTATUS[0]}"
ls -l /tmp/rdma_fft_server 2>/dev/null || echo "no binary produced"
