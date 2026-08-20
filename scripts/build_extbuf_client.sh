#!/usr/bin/env bash
# Build the Phase 3 step 5 sender on the PXI.
#
# Two stages, because the PXI has never built grpc-direct with the rdma feature.
# The library comes first and its failure is reported on its own, so a linker
# error in our client is not confused with a missing backend.
set -u
export PATH="$HOME/.cargo/bin:/usr/bin:/bin"

GD="$HOME/grpc-direct"
SRC="$HOME/extbuf_p3"

echo "== stage 1: grpc-direct with --features rdma =="
cd "$GD" || { echo "NO_GRPC_DIRECT"; exit 1; }
export EASYRDMA_LIB_DIR="$HOME/easyrdma/core/build"
export EASYRDMA_INC_DIR="$HOME/easyrdma/core/api"
cargo build --release --features rdma 2>&1 | tail -30
rc=${PIPESTATUS[0]}
echo "CARGO_EXIT=$rc"
[ "$rc" -eq 0 ] || exit 1

nm -D --defined-only target/release/libgrpc_direct.so \
  | grep -E 'grpc_direct_client_(create|send|destroy)' \
  || { echo "NO_CLIENT_SYMBOLS"; exit 1; }

echo "== stage 2: the client =="
mkdir -p "$SRC"; cd "$SRC" || exit 1
for f in extbuf_fft_client.cc rdma_contract.h signal_gen.cc signal_gen.h; do
  [ -f "$f" ] || { echo "MISSING $f in $SRC"; exit 1; }
done

g++ -O2 -std=c++17 -o extbuf_fft_client \
    extbuf_fft_client.cc signal_gen.cc \
    -I. -I"$GD/include" \
    -L"$GD/target/release" -lgrpc_direct -pthread 2>&1 | tail -30
echo "BUILD_EXIT=${PIPESTATUS[0]}"

ls -l "$SRC/extbuf_fft_client" 2>/dev/null
