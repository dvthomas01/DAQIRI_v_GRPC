#!/usr/bin/env bash
# Correctness check for E2 (--zc-align, in-place FFT from mapped host memory).
#
# E2 removes the realign copy by letting cuFFT read the 8-byte-aligned protobuf
# store directly.  That is a real change to what cuFFT is handed, so prove the
# spectrum is unchanged before trusting the 1.68x speedup.
#
# Three arms per size, --verify prints the top-3 peaks of the first measured
# buffer.  All three must agree on both frequency and magnitude:
#   copy : no --zero-copy at all (CPU memcpy -> device FFT).  GROUND TRUTH.
#   base : --zero-copy            (D2D realign -> device FFT)
#   e2   : --zero-copy --zc-align (in-place FFT from mapped host)
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
SIZES="${SIZES:-4096 65536 1048576}"
N=60; W=10; PACE=400; PORT=50100

clean_shmem () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

arm_flags () {
    case "$1" in
        copy) echo "" ;;
        base) echo "--zero-copy" ;;
        e2)   echo "--zero-copy --zc-align" ;;
    esac
}

clean_shmem
for S in $SIZES; do
  KB=$(( S * 4 / 1024 ))
  echo "================================================================"
  echo "=== size=$S samples (${KB} KB)"
  echo "================================================================"
  for ARM in copy base e2; do
    FLAGS=$(arm_flags "$ARM")
    LOG="/tmp/vfy_${ARM}_${S}.log"
    clean_shmem
    rm -f "data/vfy_${ARM}_${S}.csv"
    timeout 120 $SERVER --port $PORT --bufsize $S --n-buffers $N --warmup $W \
        --out "data/vfy_${ARM}_${S}.csv" --transport shmem --one-shot --verify \
        $FLAGS >"$LOG" 2>&1 &
    SPID=$!
    sleep 4
    timeout 100 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize $S --n-buffers $N --warmup $W --pace-us $PACE >>"$LOG" 2>&1
    wait $SPID 2>/dev/null

    mode=$(awk -F': *' '/feed mode/{print $2; exit}' "$LOG")
    printf "%-5s [%s] " "$ARM" "${mode:-copy path}"
    grep -a '\[verify\]' "$LOG" | sed 's/^\[verify\] //' || echo "NO VERIFY LINE"
  done
  echo
done
clean_shmem
echo ALLDONE
