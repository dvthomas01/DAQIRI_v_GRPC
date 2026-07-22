#!/usr/bin/env bash
# daqiri_zc_sweep.sh [TRIALS]
# Copy-vs-zero-copy sweep for Pipeline A (DAQiri socket -> H->D -> cuFFT).
# The DAQiri pipeline binary runs TX+RX in-process (no pacing flag), so each
# mode is the native DAQiri feed rate.  Every trial CSV is written as
# data/dqzc_<mode>_<BS>_<trial>.csv  (mode in {copy, zerocopy}).
set -u
cd "$HOME/daqiri_gpu"

BIN="build/daqiri/bench_daqiri_pipeline"
YAML="daqiri/config_pipeline.yaml"
TRIALS=${1:-3}
N=1000; W=100

run_one () {
    local BS=$1 MODE=$2 CSV=$3
    local ZC=""
    [ "$MODE" = "zerocopy" ] && ZC="--zero-copy"
    pkill -9 -f bench_daqiri_pipeline 2>/dev/null || true
    sleep 1
    rm -f "$CSV"
    "$BIN" --yaml "$YAML" --bufsize "$BS" --n-buffers "$N" --warmup "$W" \
           --out "$CSV" $ZC >/dev/null 2>&1
}

echo "=== DAQiri copy vs zero-copy sweep  trials=${TRIALS}  N=${N} W=${W} ==="
for BS in 4096 8192 16384 32768; do
    for MODE in copy zerocopy; do
        for TRIAL in $(seq 1 "$TRIALS"); do
            CSV="data/dqzc_${MODE}_${BS}_${TRIAL}.csv"
            echo "  run BS=$BS mode=$MODE trial=$TRIAL"
            run_one "$BS" "$MODE" "$CSV"
        done
    done
done
pkill -9 -f bench_daqiri_pipeline 2>/dev/null || true
echo "ALLDONE"
