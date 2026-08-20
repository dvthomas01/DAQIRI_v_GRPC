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
# bindgen needs libclang to build iceoryx2-pal-posix. The PXI has no clang
# package, but the Python clang bindings ship a copy and bindgen only needs the
# shared library, not a compiler driver. iceoryx2 is an unconditional
# dependency of grpc-direct rather than an optional one, so it cannot be
# dropped even though the RDMA client never touches shared memory.
export LIBCLANG_PATH="/usr/lib/python3.12/site-packages/clang/native"
[ -f "$LIBCLANG_PATH/libclang.so" ] || echo "WARN: no libclang at $LIBCLANG_PATH"
# That libclang ships without its resource directory, so it cannot find its own
# freestanding headers and dies on stddef.h while parsing glibc. GCC's builtin
# include directory supplies the same headers, and bindgen only needs to parse
# POSIX declarations here rather than produce code, so borrowing them is safe.
GCC_INC=$(find /usr/lib/gcc -name stddef.h 2>/dev/null | head -1)
GCC_INC=${GCC_INC%/stddef.h}
[ -n "$GCC_INC" ] || echo "WARN: no gcc builtin include dir found"
export BINDGEN_EXTRA_CLANG_ARGS="-I$GCC_INC"
echo "LIBCLANG_PATH=$LIBCLANG_PATH"
echo "BINDGEN_EXTRA_CLANG_ARGS=$BINDGEN_EXTRA_CLANG_ARGS"
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
    -L"$GD/target/release" -lgrpc_direct \
    -L"$EASYRDMA_LIB_DIR" -leasyrdma \
    -Wl,--disable-new-dtags \
    -Wl,-rpath,"$GD/target/release" -Wl,-rpath,"$EASYRDMA_LIB_DIR" \
    -pthread 2>&1 | tail -30
echo "BUILD_EXIT=${PIPESTATUS[0]}"

ls -l "$SRC/extbuf_fft_client" 2>/dev/null && \
  ldd "$SRC/extbuf_fft_client" | grep -E 'grpc_direct|easyrdma|not found'
