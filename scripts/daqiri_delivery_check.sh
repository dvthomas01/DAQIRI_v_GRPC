#!/usr/bin/env bash
# Quick DAQiri-only delivery check across the extended size range.
# Answers: was the 128 KB fall-off a CONFIG ceiling (now fixed) or a DAQiri
# native limit? Reports delivered rows per (size, mode). Full = ~N rows.
set -u
cd "$HOME/daqiri_gpu"

DAQ_BIN="build/daqiri/bench_daqiri_pipeline"
YAML="daqiri/config_pipeline.yaml"
N=1000; W=100; PACE=400

rows_of () { [ -f "$1" ] && awk 'END{print NR-1}' "$1" || echo -1; }

printf "%-10s %-9s %-8s %-8s\n" "samples" "bytes" "mode" "rows"
for BS in 32768 65536 131072 262144 524288 1048576; do
    BYTES=$(( BS * 4 ))
    for MODE in copy zerocopy; do
        ZC=""; [ "$MODE" = "zerocopy" ] && ZC="--zero-copy"
        CSV="/tmp/val_${MODE}_${BS}.csv"
        pkill -9 bench_daqiri_pipeline 2>/dev/null || true
        sleep 1
        rm -f "$CSV"
        taskset -c 9,11 "$DAQ_BIN" --yaml "$YAML" --bufsize "$BS" \
            --n-buffers "$N" --warmup "$W" --pace-us "$PACE" --out "$CSV" $ZC \
            >/dev/null 2>&1
        printf "%-10s %-9s %-8s %-8s\n" "$BS" "$BYTES" "$MODE" "$(rows_of "$CSV")"
    done
done
pkill -9 bench_daqiri_pipeline 2>/dev/null || true
echo "VALDONE (full delivery = ~${N} rows; MIN acceptable ~800)"
