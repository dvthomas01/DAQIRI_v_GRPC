#!/usr/bin/env bash
# gRPC-Direct FFT sweep — all sizes to 4 MB, shmem transport.
# Params MATCH scripts/roce_sweep.sh exactly (N=200 W=50 pace=400us) so the
# per-size percentiles line up 1:1 with data/daqiri_roce_{mode}_{size}.csv.
#
# Three arms, all in one run.  GPU clocks cannot be locked on this box and the
# same FFT has been observed at 45.6 and 63.2 us across runs, so before/after
# must be measured back to back to mean anything:
#
#   copy     : staging buffer + cudaMemcpy      (original control)
#   zcbase   : zero-copy, pre-fix alignment rule (D2D realign on every message)
#   zerocopy : zero-copy, current default        (cuFFT alignment probe, E2)
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
SIZES="4096 8192 16384 32768 65536 131072 262144 524288 1048576"
N=200; W=50; PACE=400; PORT=50097
EXPECT=$N

clean_shmem () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}
rows_of () { [ -f "$1" ] && awk 'END{print NR-1}' "$1" || echo -1; }

printf "%-10s %-9s %-6s %-7s %-7s %-9s %-9s %-9s %-8s %-9s %s\n" \
  "mode" "size" "KB" "rows" "meas" "e2e_p50" "e2e_p99" "xfer_p50" "fft_p50" "MB/s" "result"
echo "----------------------------------------------------------------------------------------------"

clean_shmem
for MODE in copy zcbase zerocopy; do
  case "$MODE" in
    copy)     ZC="" ;;
    zcbase)   ZC="--zero-copy --no-zc-align" ;;
    zerocopy) ZC="--zero-copy" ;;
  esac
  for S in $SIZES; do
    KB=$(( S * 4 / 1024 ))
    CSV="data/grpc_${MODE}_${S}.csv"
    LOG="/tmp/grpc_${MODE}_${S}.log"
    clean_shmem
    rm -f "$CSV"
    timeout 120 $SERVER --port $PORT --bufsize $S --n-buffers $N --warmup $W \
        --out "$CSV" --transport shmem --one-shot $ZC >"$LOG" 2>&1 &
    SPID=$!
    sleep 4
    timeout 100 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize $S --n-buffers $N --warmup $W --pace-us $PACE >>"$LOG" 2>&1
    wait $SPID 2>/dev/null

    rows=$(rows_of "$CSV")
    meas=$(grep -aoE 'n_measured=[0-9]+' "$LOG" | head -1 | cut -d= -f2)
    e2e50=$(awk '/E2E p50/{print $4; exit}' "$LOG")
    e2e99=$(awk '/E2E p50/{print $8; exit}' "$LOG")
    xfer50=$(awk '/H->D p50/{print $4; exit}' "$LOG")
    fft50=$(awk '/cuFFT p50/{print $4; exit}' "$LOG")
    mbps=$(awk '/Throughput/{print $3; exit}' "$LOG")
    if grep -qa 'PASSED' "$LOG"; then res=PASSED
    elif [ "${rows:-0}" -ge $(( EXPECT * 80 / 100 )) ] 2>/dev/null; then res=PARTIAL
    else res=FAILED; fi
    printf "%-10s %-9s %-6s %-7s %-7s %-9s %-9s %-9s %-8s %-9s %s\n" \
      "$MODE" "$S" "$KB" "${rows:-NA}" "${meas:-NA}" "${e2e50:-NA}" "${e2e99:-NA}" \
      "${xfer50:-NA}" "${fft50:-NA}" "${mbps:-NA}" "$res"
  done
done
clean_shmem
echo "DONE_GRPC_SWEEP"
