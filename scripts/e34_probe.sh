#!/usr/bin/env bash
# E3 / E4 — close the remaining ~12 us gap to DAQiri, which now lives entirely
# inside the FFT itself.
#
# After E2 the plumbing is fixed (residual 6.97 us vs DAQiri's 4.93).  What is
# left is that an in-place FFT reads host memory and is slower than an FFT over
# device memory.  Measured at 4 MB:
#     cudaMalloc'd device memory        45.57 us   (base, after its copy)
#     DAQiri's cudaHostAlloc'd MR       58.75 us
#     our cudaHostRegister'd heap block 68.93 us   (E2, in-place)
# So the mapping quality of the source buffer is worth ~23 us.
#
#   e2  : --zc-align              current best, in-place. REFERENCE.
#   e3  : --zc-kernel             SM copy -> device-memory FFT.  Beats e2 only
#                                 if the kernel copy costs < ~24 us at 4 MB.
#   e4  : --zc-align --zc-bigreg  in-place, but register whole 64 KB GPU pages
#                                 the way DAQiri does, targeting 68.93 -> 58.75.
#   e34 : --zc-kernel --zc-bigreg both.
#
# NOTE: the first attempt at this ran with CMAKE_CUDA_ARCHITECTURES=90 while the
# GB10 is sm_121, so the E3 kernel had no image and never ran.  It failed
# silently and produced an all-zero spectrum that looked like a 53 us win.
# launch_realign_copy now checks cudaGetLastError, and the build targets native.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
SIZES="${SIZES:-4096 65536 1048576}"
ARMS="${ARMS:-e2 e3 e4 e34}"
N=200; W=50; PACE=400; PORT=50101

clean_shmem () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

arm_flags () {
    case "$1" in
        e2)  echo "--zc-align" ;;
        e3)  echo "--zc-kernel" ;;
        e4)  echo "--zc-align --zc-bigreg" ;;
        e34) echo "--zc-kernel --zc-bigreg" ;;
    esac
}

run_one () {  # $1=arm $2=size $3=extra flags $4=logfile
    local ARM="$1" S="$2" EXTRA="$3" LOG="$4"
    clean_shmem
    rm -f "data/e34_${ARM}_${S}.csv"
    timeout 120 $SERVER --port $PORT --bufsize "$S" --n-buffers $N --warmup $W \
        --out "data/e34_${ARM}_${S}.csv" --transport shmem --one-shot \
        --zero-copy --stage-timing $(arm_flags "$ARM") $EXTRA >"$LOG" 2>&1 &
    local SPID=$!
    sleep 4
    timeout 100 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize "$S" --n-buffers $N --warmup $W --pace-us $PACE >>"$LOG" 2>&1
    wait $SPID 2>/dev/null
}

printf "%-5s %-9s %-6s %-6s %-20s %-9s %-9s %-9s %-9s %-9s\n" \
  "arm" "size" "KB" "meas" "feed_mode" "e2e_p50" "e2e_p99" "fft_p50" "wall_p50" "wall-fft"
echo "----------------------------------------------------------------------------------------------------"

clean_shmem
for S in $SIZES; do
  KB=$(( S * 4 / 1024 ))
  for ARM in $ARMS; do
    LOG="/tmp/e34_${ARM}_${S}.log"
    run_one "$ARM" "$S" "" "$LOG"
    meas=$(grep -aoE 'n_measured=[0-9]+' "$LOG" | head -1 | cut -d= -f2)
    mode=$(awk -F': *' '/feed mode/{print $2; exit}' "$LOG")
    e2e50=$(awk '/E2E p50/{print $4; exit}' "$LOG")
    e2e99=$(awk '/E2E p50/{print $8; exit}' "$LOG")
    fft50=$(awk '/cuFFT p50/{print $4; exit}' "$LOG")
    wall50=$(awk '/fft call \(wall\)/{print $6; exit}' "$LOG")
    delta=$(awk -v a="${wall50:-}" -v b="${fft50:-}" \
            'BEGIN{ if (a=="" || b=="") print "NA"; else printf "%.2f", a-b }')
    printf "%-5s %-9s %-6s %-6s %-20s %-9s %-9s %-9s %-9s %-9s\n" \
      "$ARM" "$S" "$KB" "${meas:-NA}" "${mode:-NA}" "${e2e50:-NA}" "${e2e99:-NA}" \
      "${fft50:-NA}" "${wall50:-NA}" "$delta"
  done
  echo "----------------------------------------------------------------------------------------------------"
done

# Correctness: the E3 kernel is new code, so prove the spectrum still matches.
echo
echo "=== correctness (top-3 peaks must match across arms) ==="
for ARM in e2 e3 e4 e34; do
    LOG="/tmp/vfy34_${ARM}.log"
    run_one "$ARM" 1048576 "--verify" "$LOG"
    printf "%-5s " "$ARM"
    grep -a '\[verify\]' "$LOG" | sed 's/^\[verify\] //' || echo "NO VERIFY LINE"
done

clean_shmem
echo
echo "=== feed-mode decision lines ==="
grep -ah 'zero-copy\]' /tmp/e34_*.log | sort -u
echo ALLDONE
