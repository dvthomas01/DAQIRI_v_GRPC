#!/usr/bin/env bash
# Summarise an extbuf run CSV: mean end-to-end, mean transform, and the
# residual between them.  Reported separately because a bare median hides
# which half moved.
f=${1:-/tmp/ext5.csv}
awk -F, 'NR>1 && $9==1 {n++; e+=$5; t+=$6; if(NR>2){if(e5==0||$5<mn)mn=$5}}
         END {printf "n=%d  mean_e2e=%.2f us  mean_fft=%.2f us  residual=%.2f us\n",
                     n, e/n, t/n, (e-t)/n}' "$f"
# medians, warmup row excluded
tail -n +3 "$f" | cut -d, -f5 | sort -n | awk '{a[NR]=$1} END{printf "e2e   p50=%.2f p99=%.2f (n=%d, first row dropped)\n", a[int(NR*0.5)], a[int(NR*0.99)], NR}'
tail -n +3 "$f" | cut -d, -f6 | sort -n | awk '{a[NR]=$1} END{printf "fft   p50=%.2f p99=%.2f\n", a[int(NR*0.5)], a[int(NR*0.99)]}'
echo "--- gpu ---"
nvidia-smi --query-gpu=clocks.sm,clocks.max.sm,temperature.gpu,utilization.gpu --format=csv,noheader 2>/dev/null
