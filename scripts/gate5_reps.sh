#!/usr/bin/env bash
# Three reps of Gate 5 at different sizes and offsets. A gate that passes once
# at one offset has not shown that the offset was free to choose.
set -u
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
cd "$HOME/daqiri_gpu/scripts" || exit 1
export LD_LIBRARY_PATH="$HOME/easyrdma/core/build"

run() {
  echo "######## rep $1: msg=$2 offset=$3 port=$4 ########"
  ./gate5_extbuf --msg "$2" --offset "$3" --port "$4" 2>&1 | tail -6
  echo "rep $1 exit: ${PIPESTATUS[0]}"
  echo
}

run 1 1048576 4194304  18700
run 2 65536   1048577  18710   # deliberately unaligned offset
run 3 4194304 33554432 18720   # 4 MiB payload, offset deep in the pool
