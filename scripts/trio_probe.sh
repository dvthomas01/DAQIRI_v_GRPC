#!/usr/bin/env bash
# The trio — attack the fixed residual, not the transform.
#
# After the alignment fix the residual (e2e - fft_exec) is flat but still sits
# above DAQiri's: 5.7-7.1 us here vs 4.9 us there, across every size.  That
# ~0.8-2.2 us IS the whole remaining gap.  It is launch + completion overhead,
# so these three arms target it directly:
#
#   cur   : current default (E2 alignment probe, null stream, blocking sync)
#   nl    : --opt-nolock    drop the per-message global mutex + map lookup
#   st    : --opt-stream    dedicated non-blocking stream + spin-poll completion
#   af    : --opt-affinity  pin the handler thread to a fixed core
#   all   : --opt-nolock --opt-stream --opt-affinity
#
# Watch two columns: e2e_p50 (does the median move) and resid (e2e - fft, the
# thing we are actually attacking).  p99 matters too; spin-waiting should help
# the tail most.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
SIZES="${SIZES:-4096 65536 1048576}"
ARMS="${ARMS:-cur nl st af all}"
CORE="${CORE:-3}"
N=200; W=50; PACE=400; PORT=50103

clean_shmem () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

arm_flags () {
    # --opt-stream is now ON by default, so the "cur" control has to ask for the
    # legacy null stream + blocking sync explicitly.
    case "$1" in
        cur) echo "--no-opt-stream" ;;
        nl)  echo "--no-opt-stream --opt-nolock" ;;
        st)  echo "" ;;
        af)  echo "--no-opt-stream --opt-affinity $CORE" ;;
        all) echo "--opt-nolock --opt-affinity $CORE" ;;
    esac
}

printf "%-5s %-9s %-6s %-6s %-9s %-9s %-9s %-8s %-8s\n" \
  "arm" "size" "KB" "meas" "e2e_p50" "e2e_p99" "fft_p50" "resid" "d_p50"
echo "----------------------------------------------------------------------------------"

clean_shmem
for S in $SIZES; do
  KB=$(( S * 4 / 1024 ))
  BASE50=""
  for ARM in $ARMS; do
    FLAGS=$(arm_flags "$ARM")
    CSV="data/trio_${ARM}_${S}.csv"
    LOG="/tmp/trio_${ARM}_${S}.log"
    clean_shmem
    rm -f "$CSV"
    timeout 150 $SERVER --port $PORT --bufsize $S --n-buffers $N --warmup $W \
        --out "$CSV" --transport shmem --one-shot --zero-copy --verify \
        $FLAGS >"$LOG" 2>&1 &
    SPID=$!
    sleep 4
    timeout 130 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
        --bufsize $S --n-buffers $N --warmup $W --pace-us $PACE >>"$LOG" 2>&1
    wait $SPID 2>/dev/null

    meas=$(grep -aoE 'n_measured=[0-9]+' "$LOG" | head -1 | cut -d= -f2)
    e2e50=$(awk '/E2E p50/{print $4; exit}' "$LOG")
    e2e99=$(awk '/E2E p50/{print $8; exit}' "$LOG")
    fft50=$(awk '/cuFFT p50/{print $4; exit}' "$LOG")
    resid=$(awk -v a="${e2e50:-0}" -v b="${fft50:-0}" 'BEGIN{printf "%.2f", a-b}')
    [ -z "$BASE50" ] && BASE50="${e2e50:-0}"
    d50=$(awk -v a="${e2e50:-0}" -v b="$BASE50" 'BEGIN{printf "%+.2f", a-b}')

    printf "%-5s %-9s %-6s %-6s %-9s %-9s %-9s %-8s %-8s\n" \
      "$ARM" "$S" "$KB" "${meas:-NA}" "${e2e50:-NA}" "${e2e99:-NA}" \
      "${fft50:-NA}" "$resid" "$d50"
  done
  echo "----------------------------------------------------------------------------------"
done

echo
echo "==== correctness (top-3 peaks must be identical across arms) ===="
for S in $SIZES; do
  echo "--- $(( S * 4 / 1024 )) KB ---"
  for ARM in $ARMS; do
    LOG="/tmp/trio_${ARM}_${S}.log"
    [ -f "$LOG" ] || continue
    printf "%-5s " "$ARM"; grep -a 'top-3 peaks' "$LOG" | head -1
  done
done
clean_shmem
