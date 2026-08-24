#!/bin/sh
# Does the extbuf arm need a longer warmup than DAQiri to be measured fairly?
#
# The four-arm interleaved sweep gave extbuf e2e p50 42.06 us at 16 KB against
# 9.63 us for the same binary and the same size in the streaming loopback sweep,
# and 11.38 us for DAQiri in the very same rotation.  The two harnesses differ
# in exactly one thing that could do that: the streaming sweep warms extbuf with
# order 10^5 messages, the headline sweep warms it with 50.
#
# Measured window is held at 200 messages for every point so that only the
# warmup varies.  Pacing stays at 400 us because that is the regime the headline
# table is taken in and an unpaced extbuf would not be comparable to DAQiri.
set -u
cd "$HOME/daqiri_gpu" || exit 1

IP=192.168.20.1
PORT=18851
NPTS="${NPTS:-4096}"
MSGS=200
PACE=400

echo "npts=$NPTS  measured=$MSGS  pace=${PACE}us"
echo "warmup   e2e_p50   fft_p50   n"

for WU in 50 500 2000 20000; do
    pkill -9 -f extbuf_fft >/dev/null 2>&1
    sleep 1
    /tmp/extbuf_fft_server --addr $IP --port $PORT --npts "$NPTS" \
        --warmup "$WU" --msgs $MSGS --slots 4 --csv /tmp/wu.csv \
        --sha wu --verify off >/tmp/wu.srv 2>&1 &
    spid=$!
    sleep 2
    ( cd /tmp && GRPC_DIRECT_RDMA_LOCAL=$IP /tmp/extbuf_fft_client \
        --host $IP --port $PORT --npts "$NPTS" --msgs $((WU + MSGS)) \
        --warmup "$WU" --pace-us $PACE --linger-ms 400 --gen inplace \
        --csv /tmp/wu.cli.csv ) >/tmp/wu.cli 2>&1
    wait $spid 2>/dev/null

    p50=$(tail -n +2 /tmp/wu.csv | cut -d, -f5 | grep -E '^[0-9.]+$' | sort -g \
          | awk '{v[n++]=$1} END{if(n) printf "%.3f", v[int(0.5*(n-1))]}')
    f50=$(tail -n +2 /tmp/wu.csv | cut -d, -f6 | grep -E '^[0-9.]+$' | sort -g \
          | awk '{v[n++]=$1} END{if(n) printf "%.3f", v[int(0.5*(n-1))]}')
    n=$(tail -n +2 /tmp/wu.csv | wc -l)
    printf "%-8s %-9s %-9s %s\n" "$WU" "${p50:-NA}" "${f50:-NA}" "$n"
done

pkill -9 -f extbuf_fft >/dev/null 2>&1
echo "DONE_WARMUP_PROBE"
