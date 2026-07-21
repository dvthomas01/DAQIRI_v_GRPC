#!/bin/bash
# M6 — Nsight Systems profiling for Pipeline A (DAQiri → CUDA → cuFFT)
set -e

BINARY="$(pwd)/build/daqiri/bench_daqiri_pipeline"
YAML="$(pwd)/daqiri/config_pipeline.yaml"
N_BUFFERS=300
WARMUP=50
OUTDIR="$(pwd)/data/nsight"

mkdir -p "$OUTDIR"

echo "============================================"
echo " M6 — Nsight Systems Profiling (Pipeline A)"
echo "  binary    : $BINARY"
echo "  n_buffers : $N_BUFFERS  warmup: $WARMUP"
echo "  output    : $OUTDIR"
echo "============================================"

for BS in 4096 8192 16384 32768; do
    echo ""
    echo "── Profiling bufsize = $BS samples ──"
    REP="${OUTDIR}/profile_${BS}"

    # Run nsys profile – trace CUDA API + kernels + OS runtime
    nsys profile \
        --output "$REP" \
        --trace=cuda,osrt \
        --force-overwrite=true \
        "$BINARY" \
        --yaml "$YAML" \
        --bufsize "$BS" \
        --n-buffers "$N_BUFFERS" \
        --warmup "$WARMUP" \
        2>/dev/null
    echo "  profile : ${REP}.nsys-rep"

    # Extract GPU kernel summary (cuFFT kernels)
    nsys stats \
        --report cuda_gpu_kern_sum \
        --format csv \
        --force-export=true \
        --output "${OUTDIR}/profile_${BS}" \
        "${REP}.nsys-rep" \
        2>/dev/null || true

    # Extract GPU memory-op summary (H→D copy timing)
    nsys stats \
        --report cuda_gpu_mem_time_sum \
        --format csv \
        --force-export=true \
        --output "${OUTDIR}/profile_${BS}" \
        "${REP}.nsys-rep" \
        2>/dev/null || true

    # Extract CUDA API summary
    nsys stats \
        --report cuda_api_sum \
        --format csv \
        --force-export=true \
        --output "${OUTDIR}/profile_${BS}" \
        "${REP}.nsys-rep" \
        2>/dev/null || true

    echo "  stats    : ${OUTDIR}/profile_${BS}_cuda_gpu_kern_sum.csv"
    echo "  memops   : ${OUTDIR}/profile_${BS}_cuda_gpu_mem_time_sum.csv"
    echo "  api      : ${OUTDIR}/profile_${BS}_cuda_api_sum.csv"
done

echo ""
echo "============================================"
echo " Nsight profiling complete."
echo " Generating M6 figures..."
echo "============================================"
source ~/grpc-bench-env/bin/activate
python3 scripts/plot_m6_nsight.py \
    --nsight data/nsight \
    --m5data data \
    --out data/figures

echo ""
echo "==== M6 COMPLETE ===="
