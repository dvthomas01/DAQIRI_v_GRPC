#!/usr/bin/env bash
# Build the daqiri_gpu_fft project on Spark (aarch64 / DGX OS / Ubuntu 24.04).
# Run from the project root: bash scripts/build.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_DIR}/build"

echo "=== DAQiri GPU FFT — CMake build ==="
echo "Repo  : ${REPO_DIR}"
echo "Build : ${BUILD_DIR}"
echo "Arch  : $(uname -m)"
echo

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Ensure nvcc is on PATH (DGX Spark: /usr/local/cuda-13.2/bin)
CUDA_BIN="$(ls -d /usr/local/cuda-*/bin 2>/dev/null | sort -V | tail -1)"
if [[ -n "${CUDA_BIN}" ]]; then
    export PATH="${CUDA_BIN}:${PATH}"
    echo "CUDA bin: ${CUDA_BIN}"
else
    echo "WARNING: could not find /usr/local/cuda-*/bin — nvcc must already be in PATH"
fi

# Configure
# SM 90 = Grace Hopper (GH200) on DGX Spark.
# Override: cmake .. -DCMAKE_CUDA_ARCHITECTURES=<sm>
cmake "${REPO_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_ARCHITECTURES=90 \
    -DCMAKE_CUDA_COMPILER="${CUDA_BIN}/nvcc"

echo
echo "--- Building ---"
cmake --build . --parallel "$(nproc)"

echo
echo "=== Build complete ==="
echo "Binaries:"
echo "  ${BUILD_DIR}/fft/fft_validate   — run to verify FFT correctness"
echo
echo "Quick test:"
echo "  ${BUILD_DIR}/fft/fft_validate && echo 'M1 PASSED'"
