#!/usr/bin/env bash
# Build the RDMA sender ON THE SPARK.
#
# scripts/build_extbuf_client.sh is the PXI recipe: it builds the grpc-direct
# fork from source first, because the PXI had never done so. The Spark already
# has the library built with --features rdma (the server links against the same
# one), so this only compiles the client, with the same DT_RPATH treatment the
# server build uses and for the same reason: libeasyrdma is a dependency of
# libgrpc_direct rather than of us, and DT_RUNPATH is not searched transitively.
set -u
GD="$HOME/grpc-direct"
ER="$HOME/easyrdma/core/build"
SRC="$HOME/daqiri_gpu/rdma"

ls -l "$GD/target/release/libgrpc_direct.so" || { echo "NO_LIB"; exit 1; }
nm -D --defined-only "$GD/target/release/libgrpc_direct.so" \
  | grep -E 'grpc_direct_client_(create|send|destroy)' \
  || { echo "NO_CLIENT_SYMBOLS"; exit 1; }

cd "$SRC" || exit 1
g++ -O2 -std=c++17 \
    -I. -I../common -I"$GD/include" \
    -o /tmp/extbuf_fft_client \
    extbuf_fft_client.cc ../common/signal_gen.cc \
    -L"$GD/target/release" -lgrpc_direct \
    -L"$ER" -leasyrdma \
    -Wl,--disable-new-dtags \
    -Wl,-rpath,"$GD/target/release" -Wl,-rpath,"$ER" \
    -pthread 2>&1 | tail -40
echo "BUILD_EXIT=${PIPESTATUS[0]}"

ls -l /tmp/extbuf_fft_client 2>/dev/null && \
  ldd /tmp/extbuf_fft_client | grep -E 'grpc_direct|easyrdma|not found'
