#!/usr/bin/env bash
# TRUE zero-copy RoCE FFT headline sweep — all sizes to 4 MB, copy vs zero-copy.
set -u
cd ~/daqiri_gpu || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin

BIN=./build/daqiri/bench_daqiri_roce_pipeline
YAML=daqiri/config_roce_pipeline.yaml
SIZES="4096 8192 16384 32768 65536 131072 262144 524288 1048576"
NBUF=200
WARMUP=50
PACE=400

pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
sleep 1

printf "%-10s %-10s %-8s %-9s %-9s %-9s %-9s %-9s %-8s %s\n" \
  "mode" "size" "KB" "rx" "drop" "e2e_p50" "e2e_p99" "xfer_p50" "fft_p50" "MB/s"
echo "--------------------------------------------------------------------------------------------"

for MODE in copy zerocopy; do
  ZC=""; [ "$MODE" = "zerocopy" ] && ZC="--zero-copy"
  for S in $SIZES; do
    KB=$(( S * 4 / 1024 ))
    OUT="data/daqiri_roce_${MODE}_${S}.csv"
    LOG="/tmp/roce_${MODE}_${S}.log"
    timeout 90 $BIN --yaml $YAML --bufsize $S --n-buffers $NBUF --warmup $WARMUP \
        --pace-us $PACE $ZC --out "$OUT" >"$LOG" 2>&1
    EX=$?
    rx=$(grep -a 'RX rcvd' "$LOG" | grep -aoE '[0-9]+' | head -1)
    drop=$(grep -a 'Dropped buffers' "$LOG" | grep -aoE '[0-9]+' | head -1)
    e2e50=$(awk '/E2E latency/{f=1} f&&/p50/{print $3; exit}' "$LOG")
    e2e99=$(awk '/E2E latency/{f=1} f&&/p99/{print $3; exit}' "$LOG")
    xfer50=$(awk '/transfer latency/{f=1} f&&/p50/{print $3; exit}' "$LOG")
    fft50=$(awk '/cuFFT execution/{f=1} f&&/p50/{print $3; exit}' "$LOG")
    mbps=$(grep -a 'Throughput' "$LOG" | grep -aoE '[0-9.]+' | head -1)
    pass=$(grep -aoE 'PASSED|FAILED' "$LOG" | head -1)
    printf "%-10s %-10s %-8s %-9s %-9s %-9s %-9s %-9s %-8s %-8s %s(ex=%s)\n" \
      "$MODE" "$S" "$KB" "${rx:-NA}" "${drop:-NA}" "${e2e50:-NA}" "${e2e99:-NA}" \
      "${xfer50:-NA}" "${fft50:-NA}" "${mbps:-NA}" "${pass:-NORESULT}" "$EX"
    pkill -9 -f bench_daqiri_roce_pipeline 2>/dev/null
    sleep 1
  done
done
echo "DONE_SWEEP"
