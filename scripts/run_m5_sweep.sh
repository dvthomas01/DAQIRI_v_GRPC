#!/usr/bin/env bash
# scripts/run_m5_sweep.sh — Run the full M5 Pipeline A buffer-size sweep.
#
# Runs bench_daqiri_pipeline for all 4 buffer sizes (4096, 8192, 16384, 32768)
# with warmup + 1000 measured buffers each, then generates all figures.
#
# Usage (from repo root on Spark):
#   bash scripts/run_m5_sweep.sh
#   bash scripts/run_m5_sweep.sh --n-buffers 2000 --warmup 200

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${REPO}/build/daqiri/bench_daqiri_pipeline"
YAML="${REPO}/daqiri/config_pipeline.yaml"
DATA="${REPO}/data"
FIGS="${REPO}/data/figures"
N_BUFFERS=1000
WARMUP=100

# Parse optional overrides
while [[ $# -gt 0 ]]; do
    case $1 in
        --n-buffers) N_BUFFERS="$2"; shift 2;;
        --warmup)    WARMUP="$2";    shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

mkdir -p "${DATA}" "${FIGS}"

echo "============================================"
echo " M5 Pipeline A — Buffer-Size Sweep"
echo "  binary    : ${BINARY}"
echo "  yaml      : ${YAML}"
echo "  n_buffers : ${N_BUFFERS}  warmup: ${WARMUP}"
echo "============================================"
echo ""

for BS in 4096 8192 16384 32768; do
    echo "── bufsize = ${BS} samples ($(( BS * 4 / 1024 )) KB) ──"
    "${BINARY}" \
        --yaml      "${YAML}" \
        --bufsize   "${BS}" \
        --n-buffers "${N_BUFFERS}" \
        --warmup    "${WARMUP}" \
        --out       "${DATA}/daqiri_pipeline_${BS}.csv" \
        2>/dev/null \
      | grep -E 'p50|p95|p99|Throughput|PASSED|FAILED|CPU util|GPU util|Buffers processed'
    echo ""
done

echo "── Generating figures ──"
source ~/grpc-bench-env/bin/activate 2>/dev/null || true
python3 "${REPO}/scripts/plot_m4_pipeline.py" \
    --data "${DATA}" \
    --out  "${FIGS}"

echo ""
echo "Figures written to ${FIGS}/"
echo "M5 sweep complete."
