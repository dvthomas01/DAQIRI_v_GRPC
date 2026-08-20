#!/usr/bin/env bash
# Build the Phase 3 step 5 receiver on the Spark.
#
# Not part of the CMake tree yet, because it links libgrpc_direct.so out of the
# fork's target/release rather than anything CMake builds. Wire it in once the
# arm is real; for now a build script keeps the dependency visible.
set -u
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin

GD="$HOME/grpc-direct"
SRC="$HOME/daqiri_gpu/rdma"

echo "== grpc-direct library =="
ls -l "$GD/target/release/libgrpc_direct.so" || { echo "NO_LIB: build the fork first"; exit 1; }
nm -D --defined-only "$GD/target/release/libgrpc_direct.so" \
  | grep -E 'grpc_direct_server_(create_ext|receive_ext|slot_requeue)' \
  || { echo "NO_EXTBUF_SYMBOLS: the library predates step 4"; exit 1; }

echo "== build =="
cd "$SRC" || exit 1
nvcc -O2 -arch=native -std=c++17 \
     -I. -I../common -I../fft -I"$GD/include" \
     -o /tmp/extbuf_fft_server \
     extbuf_fft_server.cu ../fft/cufft_executor.cu ../common/signal_gen.cc \
     -L"$GD/target/release" -lgrpc_direct -lcufft \
     -Xcompiler -pthread 2>&1 | tail -40
echo "BUILD_EXIT=${PIPESTATUS[0]}"

ls -l /tmp/extbuf_fft_server 2>/dev/null && \
  echo "run with LD_LIBRARY_PATH=$GD/target/release"
