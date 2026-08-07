#!/usr/bin/env bash
# E1 / E2 — attack the realign copy that Phase 0 identified.
#
# Phase 0 finding: the protobuf backing store is align16=8, so the hard-coded
# `(dptr & 15) != 0` rule sent 100% of messages down a D2D realign copy.  That
# copy costs ~77 us at 4 MB and is hidden inside the FFT's cudaEventSynchronize,
# which is why it never showed up in the realign stage timer.
#
#   base : --zero-copy                 (control: D2D realign, current behaviour)
#   E1   : --zero-copy --zc-h2d        (realign via H2D DMA from pinned host)
#   E2   : --zero-copy --zc-align      (ask cuFFT; if it accepts, no copy at all)
#   E12  : --zero-copy --zc-align --zc-h2d  (E2, falling back to E1 if probe fails)
#
# The number that matters is `wall-fft`: fft call wall time minus the GPU event
# time.  That is the copy cost.  base should show ~77 us at 4 MB; a winning arm
# drives it toward zero.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
SIZES="${SIZES:-4096 65536 1048576}"
ARMS="${ARMS:-base e1 e2 e12}"
N=200; W=50; PACE=400; PORT=50099

clean_shmem () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

arm_flags () {
    case "$1" in
        base) echo "" ;;
        e1)   echo "--zc-h2d" ;;
        e2)   echo "--zc-align" ;;
        e12)  echo "--zc-align --zc-h2d" ;;
    esac
}

printf "%-6s %-9s %-6s %-6s %-22s %-9s %-9s %-9s %-9s %-9s\n" \
  "arm" "size" "KB" "meas" "feed_mode" "e2e_p50" "e2e_p99" "fft_p50" "wall_p50" "wall-fft"
echo "--------------------------------------------------------------------------------------------------------"

clean_shmem
for S in $SIZES; do
  KB=$(( S * 4 / 1024 ))
  for ARM in $ARMS; do
    FLAGS=$(arm_flags "$ARM")
    CSV="data/e12_${ARM}_${S}.csv"
    LOG="/tmp/e12_${ARM}_${S}.log"
    clean_shmem
    rm -f "$CSV"
    timeout 120 $SERVER --port $PORT --bufsize $S --n-buffers $N --warmup $W \
        --out "$CSV" --transport shmem --one-shot --zero-copy --stage-timing \
        $FLAGS >"$LOG" 2>&1 &
    SPID=$!
    sleep 4
    timeout 100 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize $S --n-buffers $N --warmup $W --pace-us $PACE >>"$LOG" 2>&1
    wait $SPID 2>/dev/null

    meas=$(grep -aoE 'n_measured=[0-9]+' "$LOG" | head -1 | cut -d= -f2)
    mode=$(awk -F': *' '/feed mode/{print $2; exit}' "$LOG")
    e2e50=$(awk '/E2E p50/{print $4; exit}' "$LOG")
    e2e99=$(awk '/E2E p50/{print $8; exit}' "$LOG")
    fft50=$(awk '/cuFFT p50/{print $4; exit}' "$LOG")
    wall50=$(awk '/fft call \(wall\)/{print $6; exit}' "$LOG")
    delta=$(awk -v a="${wall50:-}" -v b="${fft50:-}" \
            'BEGIN{ if (a=="" || b=="") print "NA"; else printf "%.2f", a-b }')
    printf "%-6s %-9s %-6s %-6s %-22s %-9s %-9s %-9s %-9s %-9s\n" \
      "$ARM" "$S" "$KB" "${meas:-NA}" "${mode:-NA}" "${e2e50:-NA}" "${e2e99:-NA}" \
      "${fft50:-NA}" "${wall50:-NA}" "$delta"
  done
  echo "--------------------------------------------------------------------------------------------------------"
done
clean_shmem

echo
echo "=== probe / feed-mode decision lines ==="
grep -aH 'zero-copy\]' /tmp/e12_*.log
echo ALLDONE
