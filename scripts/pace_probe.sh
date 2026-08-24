#!/bin/sh
# Is the DAQiri advantage in Table B a pacing artifact?
#
# Two facts collided.  In the streaming loopback sweep extbuf posts e2e p50 9.63
# us and cuFFT p50 4.80 us at 16 KB.  In the headline harness, same binary, same
# size, same box, it posts 40 us and 20 us, and a warmup probe just showed that
# 400x more warmup does not move either number.  The harnesses differ in pacing:
# the streaming sweep sends back to back, the headline harness sends one message
# every 400 us.  DAQiri in the same rotation posts 6.53 us of cuFFT, so whatever
# the pace does to extbuf it is not doing to DAQiri.
#
# A 4x swing in the transform term is larger than every delta Table B reports.
# Until this is understood Table B is not measuring what it claims to measure,
# so this runs before the real sweep rather than after it.
#
# Arms are rotated inside each pace so a drift cannot land on one of them.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin

IP=192.168.20.1
EXPORT_=18861
DAQ=./build/daqiri/bench_daqiri_roce_pipeline
YAML=daqiri/config_roce_pipeline.yaml
NPTS="${NPTS:-4096}"
MSGS="${MSGS:-200}"
WU="${WU:-200}"
PACES="${PACES:-0 25 100 400}"
REPS="${REPS:-2}"
OUT="${OUT:-data/pace_probe.csv}"

p50 () {
    tail -n +2 "$1" 2>/dev/null | cut -d, -f"$2" | grep -E '^[0-9.]+$' | sort -g \
      | awk '{v[n++]=$1} END{if(n) printf "%.3f", v[int(0.5*(n-1))]}'
}

clean () {
    pkill -9 -f extbuf_fft >/dev/null 2>&1
    pkill -9 -f bench_daqiri_roce_pipeline >/dev/null 2>&1
    sleep 1
}

echo "arm,npts,kb,pace_us,rep,e2e_p50,fft_p50,n,sm_mhz" > "$OUT"
printf "%-8s %-8s %-6s %-9s %-9s %-6s %s\n" arm pace rep e2e_p50 fft_p50 n sm_mhz
echo "------------------------------------------------------------------"

for P in $PACES; do
  for R in $(seq 1 "$REPS"); do
    for ARM in extbuf daq; do
      clean
      : > /tmp/pp_clk.txt
      ( while :; do
          nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits 2>/dev/null
          sleep 0.2
        done >> /tmp/pp_clk.txt ) &
      CLK=$!

      if [ "$ARM" = extbuf ]; then
        /tmp/extbuf_fft_server --addr $IP --port $EXPORT_ --npts "$NPTS" \
            --warmup "$WU" --msgs "$MSGS" --slots 4 --csv /tmp/pp.csv \
            --sha pace --verify off >/tmp/pp.srv 2>&1 &
        s=$!
        sleep 2
        ( cd /tmp && GRPC_DIRECT_RDMA_LOCAL=$IP /tmp/extbuf_fft_client \
            --host $IP --port $EXPORT_ --npts "$NPTS" --msgs $((WU + MSGS)) \
            --warmup "$WU" --pace-us "$P" --linger-ms 400 --gen inplace \
            --csv /tmp/pp.cli.csv ) >/tmp/pp.cli 2>&1
        wait $s 2>/dev/null
        E=$(p50 /tmp/pp.csv 5); F=$(p50 /tmp/pp.csv 6)
        N=$(tail -n +2 /tmp/pp.csv 2>/dev/null | wc -l)
      else
        timeout 90 $DAQ --yaml $YAML --bufsize "$NPTS" --n-buffers "$MSGS" \
            --warmup "$WU" --pace-us "$P" --zero-copy --out /tmp/pp_daq.csv \
            >/tmp/pp.daq 2>&1
        E=$(awk '/E2E latency/{f=1} f&&/p50/{print $3; exit}' /tmp/pp.daq)
        F=$(awk '/cuFFT execution/{f=1} f&&/p50/{print $3; exit}' /tmp/pp.daq)
        N=$(grep -a 'RX rcvd' /tmp/pp.daq | grep -aoE '[0-9]+' | head -1)
      fi

      kill $CLK 2>/dev/null; wait $CLK 2>/dev/null
      SM=$(tr -dc '0-9\n' < /tmp/pp_clk.txt | grep -E '^[0-9]+$' | sort -n | tail -1)

      printf "%-8s %-8s %-6s %-9s %-9s %-6s %s\n" \
        "$ARM" "$P" "$R" "${E:-NA}" "${F:-NA}" "${N:-NA}" "${SM:-NA}"
      echo "$ARM,$NPTS,$((NPTS * 4 / 1024)),$P,$R,${E:-NA},${F:-NA},${N:-NA},${SM:-NA}" >> "$OUT"
    done
  done
  echo "------------------------------------------------------------------"
done
clean
echo "DONE_PACE_PROBE -> $OUT"
