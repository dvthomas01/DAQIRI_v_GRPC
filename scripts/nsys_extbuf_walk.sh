#!/bin/sh
# Walk the 4 MiB RDMA run down in message count until nsys keeps the GPU-side
# kernel table. The threshold is a launch count: at 16 KB, 170 launches came
# back and 400 did not, and 4 MiB spends three kernels per message.
set -u
cd "$HOME/daqiri_gpu" || exit 1
for m in 40 25 15; do
    ONLY="m$m" WARM=10 MSGS="$m" PORT="1887$m" \
        sh scripts/nsys_extbuf_probe.sh 2>&1 \
        | grep -v Warning \
        | grep -E 'variant|kernel table|busy per|wall span|by kernel|us x|CUDA-event|gap between|messages in'
done
