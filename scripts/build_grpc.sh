#!/bin/bash
# build_grpc.sh — Configure and build the Pipeline B (gRPC Direct) project.
#
# Uses pre-fetched gRPC source from ~/grpc_benchmarking to avoid re-downloading.
# First build compiles gRPC + grpc-direct from source (~10-20 min).
# Subsequent builds are incremental (seconds).
#
# Usage: bash scripts/build_grpc.sh
set -e

# Cargo/Rust required by grpc-direct for the Rust FFI layer
export PATH="$PATH:$HOME/.cargo/bin"

# CUDA toolkit — must be on PATH so CMake can identify nvcc
CUDA_ROOT="/usr/local/cuda-13"
if [[ -d "$CUDA_ROOT/bin" ]]; then
    export PATH="$CUDA_ROOT/bin:$PATH"
    export CUDA_HOME="$CUDA_ROOT"
    export CUDA_TOOLKIT_ROOT_DIR="$CUDA_ROOT"
fi

BUILD_DIR="$HOME/daqiri_gpu/build_grpc"
SRC_DIR="$HOME/daqiri_gpu/grpc_direct"

echo "============================================"
echo " Pipeline B — gRPC Direct Build"
echo "  source : $SRC_DIR"
echo "  build  : $BUILD_DIR"
echo "============================================"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Remove stale cache so re-configures start clean
rm -f CMakeCache.txt

# Configure (only runs fully on first call)
cmake "$SRC_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES=90 \
    -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-13 \
    2>&1

echo ""
echo "── Building (this may take 10-20 min on first run) ──"
cmake --build "$BUILD_DIR" --parallel "$(nproc)" 2>&1

echo ""
echo "============================================"
echo " Build complete."
echo "  bench_grpc_server : $BUILD_DIR/bench_grpc_server"
echo "  bench_grpc_client : $BUILD_DIR/bench_grpc_client"
echo "============================================"
