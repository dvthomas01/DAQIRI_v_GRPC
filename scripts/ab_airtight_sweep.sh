#!/usr/bin/env bash
# ab_airtight_sweep.sh [TRIALS] [PACE]
# Airtight, matched-pair A/B sweep: DAQiri (Pipeline A) vs gRPC Direct
# (Pipeline B), copy and zero-copy, across buffer sizes.
#
# WHY THIS DESIGN (measured constraints on this GB10 box):
#   * GPU clocks CANNOT be locked (nvidia-smi: "Supported Clocks: N/A"); the GPU
#     idles at 208 MHz but boosts to 2418 MHz -> a >10x DVFS swing dominates
#     everything unless neutralised.
#   * The gRPC shmem transport CANNOT run unpaced: pace=0 stalls (server hangs)
#     and pace<200us DROPS buffers -> gRPC can never saturate the GPU.
#   * So to make the LATENCY comparison clock-fair we PACE BOTH PIPELINES
#     IDENTICALLY (default 400us): both sit in the same cool-clock regime and
#     deliver every buffer. fft_exec_us in each CSV is the built-in on-GPU clock
#     probe -- similar A/B fft times confirm the clocks matched.
#
# Controls applied:
#   * MATCHED PAIR: DAQiri then gRPC back-to-back per (BS, mode, trial) so any
#     residual thermal drift is shared.
#   * SAME PACE for both -> matched GPU duty cycle -> matched clock.
#   * AFFINITY: DAQiri self-pins RX->9/TX->11; gRPC client pinned to core 11;
#     gRPC server left free so its iceoryx/grpc background threads don't stall.
#   * DELIVERY: every run must land >= MIN_ROWS rows or it is retried (<=2 more).
#   * 5 trials (default), N=1000, W=100.
# CSVs: data/ab_daqiri_<mode>_<BS>_<trial>.csv , data/ab_grpc_<mode>_<BS>_<trial>.csv
set -u
cd "$HOME/daqiri_gpu"

DAQ_BIN="build/daqiri/bench_daqiri_pipeline"
YAML="daqiri/config_pipeline.yaml"
GRPC_SERVER="build_grpc/bench_grpc_server"
GRPC_CLIENT="build_grpc/bench_grpc_client"
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

TRIALS=${1:-5}
PACE=${2:-400}
N=1000; W=100
PORT=50096
CPU_FEED=11          # TX / client core
MIN_ROWS=800         # expect ~N-W measured rows

rows_of () { [ -f "$1" ] && awk 'END{print NR-1}' "$1" || echo -1; }

run_daqiri () {  # $1 BS  $2 MODE  $3 CSV
    local BS=$1 MODE=$2 CSV=$3 ZC=""
    [ "$MODE" = "zerocopy" ] && ZC="--zero-copy"
    local try
    for try in 1 2 3; do
        pkill -9 -f bench_daqiri_pipeline 2>/dev/null || true
        sleep 1
        rm -f "$CSV"
        taskset -c 9,11 \
            "$DAQ_BIN" --yaml "$YAML" --bufsize "$BS" --n-buffers "$N" \
            --warmup "$W" --pace-us "$PACE" --out "$CSV" $ZC >/dev/null 2>&1
        [ "$(rows_of "$CSV")" -ge "$MIN_ROWS" ] && return 0
        echo "      [retry daqiri BS=$BS $MODE try=$try rows=$(rows_of "$CSV")]"
    done
    return 0
}

run_grpc () {  # $1 BS  $2 MODE  $3 CSV
    local BS=$1 MODE=$2 CSV=$3 ZC=""
    [ "$MODE" = "zerocopy" ] && ZC="--zero-copy"
    local try
    for try in 1 2 3; do
        pkill -9 -f bench_grpc_server 2>/dev/null || true
        sleep 1
        rm -rf /tmp/iceoryx2 2>/dev/null || true
        rm -f /dev/shm/iox2_* 2>/dev/null || true
        rm -f "$CSV"
        sleep 1
        timeout 60 "$GRPC_SERVER" --port "$PORT" --bufsize "$BS" --n-buffers "$N" \
            --warmup "$W" --out "$CSV" --transport shmem --one-shot $ZC \
            >/dev/null 2>&1 &
        local SPID=$!
        sleep 4
        timeout 50 taskset -c ${CPU_FEED} \
            "$GRPC_CLIENT" --server "localhost:$PORT" --transport shmem \
            --bufsize "$BS" --n-buffers "$N" --warmup "$W" --pace-us "$PACE" \
            >/dev/null 2>&1
        wait $SPID 2>/dev/null || true
        [ "$(rows_of "$CSV")" -ge "$MIN_ROWS" ] && return 0
        echo "      [retry grpc BS=$BS $MODE try=$try rows=$(rows_of "$CSV")]"
    done
    return 0
}

echo "=== AIRTIGHT A/B sweep  matched-pair  pace=${PACE}us  trials=${TRIALS}  N=${N} W=${W} ==="
for BS in 4096 8192 16384 32768; do
    for MODE in copy zerocopy; do
        for TRIAL in $(seq 1 "$TRIALS"); do
            DCSV="data/ab_daqiri_${MODE}_${BS}_${TRIAL}.csv"
            GCSV="data/ab_grpc_${MODE}_${BS}_${TRIAL}.csv"
            echo "  pair BS=$BS mode=$MODE trial=$TRIAL"
            run_daqiri "$BS" "$MODE" "$DCSV"   # A then B, back-to-back = shared clock
            run_grpc   "$BS" "$MODE" "$GCSV"
        done
    done
done
pkill -9 -f bench_daqiri_pipeline 2>/dev/null || true
pkill -9 -f bench_grpc_server 2>/dev/null || true
echo "ALLDONE"
