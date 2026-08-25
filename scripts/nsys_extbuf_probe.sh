#!/bin/sh
# Get a GPU-side profile of the RDMA arm at 4 MiB.
#
# The question is narrow. The stage sweep says the RDMA arm's transform takes
# 71.14 us of CUDA-event time against DAQiri's 58.37, and the same CUDA events
# cannot say whether that is more kernel work or more dead time between
# kernels. nsys can, because it records each kernel's own duration. DAQiri
# already has an answer from the same instrument: 48.78 us of kernel busy
# inside 58.37 us of event time, so 9.6 us of gaps across three kernels. If the
# RDMA arm comes out near 48.78 busy then its extra time is waiting and the
# kernels are identical; if it comes out near 61 then the GPU is doing more
# work for the same transform.
#
# The earlier attempt at 4 MiB captured the API side in full, 750 cuLaunchKernel
# rows, and had no CUPTI_ACTIVITY_KIND_KERNEL table at all, while the same
# binary at 16 KB was fine. That looks like GPU-side records not making it out,
# so the variants below cut the record count and push the flushes.
set -u
cd "$HOME/daqiri_gpu" || exit 1

NSYS=/usr/local/cuda-13/bin/nsys
EXSRV=/tmp/extbuf_fft_server
EXCLI=/tmp/extbuf_fft_client
RDMA_IP=192.168.20.1
PORT="${PORT:-18861}"
NPTS="${NPTS:-1048576}"
OUTDIR=/tmp/exprof
mkdir -p "$OUTDIR"

clean () {
    pkill -9 -f extbuf_fft_server 2>/dev/null
    pkill -9 -f extbuf_fft_client 2>/dev/null
    sleep 1
}

# variant name | extra nsys args | warmup | measured
run_variant () {
    name=$1; extra=$2; warm=$3; msgs=$4
    rep=$OUTDIR/$name
    echo "=================================================================="
    echo "variant $name   warmup=$warm msgs=$msgs   extra: ${extra:-none}"
    clean
    rm -f "$rep".nsys-rep "$rep".sqlite
    # shellcheck disable=SC2086
    $NSYS profile -o "$rep" --force-overwrite=true \
        --trace=cuda --sample=none --cpuctxsw=none --cuda-memory-usage=false \
        $extra \
        $EXSRV --addr $RDMA_IP --port $PORT --npts "$NPTS" \
        --warmup "$warm" --msgs "$msgs" --slots 4 \
        --csv "$OUTDIR/$name.csv" --sha nsysprobe --verify off \
        > "$OUTDIR/$name.log" 2>&1 &
    sp=$!
    sleep 6
    ( cd /tmp && GRPC_DIRECT_RDMA_LOCAL=$RDMA_IP timeout 200 $EXCLI \
        --host $RDMA_IP --port $PORT --npts "$NPTS" --warmup "$warm" \
        --msgs $((warm + msgs)) --pace-us 25 --linger-ms 400 --gen inplace ) \
        >> "$OUTDIR/$name.log" 2>&1
    wait $sp 2>/dev/null
    clean

    if [ ! -f "$rep.nsys-rep" ]; then
        echo "  no report produced"
        return
    fi
    $NSYS export --type sqlite --force-overwrite=true -o "$rep.sqlite" \
        "$rep.nsys-rep" > /dev/null 2>&1
    python3 scripts/nsys_kernel_probe.py "$rep.sqlite" "$OUTDIR/$name.csv"
}

# The capture threshold is a launch COUNT, not a payload size. At 16 KB, one
# kernel per message, 170 launches came back and 400 did not. At 4 MiB there are
# three kernels per message, so the message budget is a third of that. These
# variants walk down until the GPU-side table survives.
if [ -n "${ONLY:-}" ]; then
    run_variant "only_${ONLY}" "--cuda-flush-interval=100" \
        "${WARM:-15}" "${MSGS:-30}"
else
    run_variant v1_plain    ""                            100 300
    run_variant v2_flush    "--cuda-flush-interval=100"   100 300
    run_variant v3_short    "--cuda-flush-interval=100"    50 120
fi
echo DONE
