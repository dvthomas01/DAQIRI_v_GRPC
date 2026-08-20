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
# libgrpc_direct.so records a DT_NEEDED on libeasyrdma.so.1, which lives here
# and nowhere on the default search path. Without it the link fails on
# easyrdma_* symbols that are not ours and that we never call directly.
# baked in as an rpath as well as a -L so the binary runs without
# LD_LIBRARY_PATH; a benchmark that only works under the right environment
# variable is a benchmark someone will eventually run under the wrong one.
#
# --disable-new-dtags matters and is not cosmetic. The modern default emits
# DT_RUNPATH, which the loader consults only for the binary's own direct
# dependencies, not for a dependency's dependencies. libeasyrdma is needed by
# libgrpc_direct rather than by us, so under DT_RUNPATH it links and then
# fails to load. DT_RPATH is searched transitively.
ER="$HOME/easyrdma/core/build"

echo "== grpc-direct library =="
ls -l "$GD/target/release/libgrpc_direct.so" || { echo "NO_LIB: build the fork first"; exit 1; }
nm -D --defined-only "$GD/target/release/libgrpc_direct.so" \
  | grep -E 'grpc_direct_server_(create_ext|receive_ext|slot_requeue)' \
  || { echo "NO_EXTBUF_SYMBOLS: the library predates step 4"; exit 1; }

echo "== easyrdma =="
ls -l "$ER/libeasyrdma.so" "$ER/libeasyrdma.so.1" 2>&1 | tail -4

echo "== build =="
cd "$SRC" || exit 1
nvcc -O2 -arch=native -std=c++17 \
     -I. -I../common -I../fft -I"$GD/include" \
     -o /tmp/extbuf_fft_server \
     extbuf_fft_server.cu ../fft/cufft_executor.cu ../common/signal_gen.cc \
     -L"$GD/target/release" -lgrpc_direct \
     -L"$ER" -leasyrdma -lcufft \
     -Xlinker --disable-new-dtags \
     -Xlinker -rpath -Xlinker "$GD/target/release" \
     -Xlinker -rpath -Xlinker "$ER" \
     -Xcompiler -pthread 2>&1 | tail -40
echo "BUILD_EXIT=${PIPESTATUS[0]}"

ls -l /tmp/extbuf_fft_server 2>/dev/null && ldd /tmp/extbuf_fft_server | grep -E 'grpc_direct|easyrdma|not found'
