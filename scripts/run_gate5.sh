#!/usr/bin/env bash
# Build and run Gate 5 on the Spark.
set -u
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
cd "$HOME/daqiri_gpu/scripts" || exit 1

ERDMA="$HOME/easyrdma"

echo "=== build ==="
nvcc -O2 -arch=native -std=c++17 -o gate5_extbuf gate5_extbuf.cu \
     -I"$ERDMA/core/api" -L"$ERDMA/core/build" -leasyrdma -lcuda \
     -Xcompiler -pthread
rc=$?
echo "build exit: $rc"
[ $rc -ne 0 ] && exit $rc

echo
echo "=== run ==="
LD_LIBRARY_PATH="$ERDMA/core/build" ./gate5_extbuf "$@"
echo "gate5 exit: $?"
