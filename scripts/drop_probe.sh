#!/usr/bin/env bash
# Drop characterization — do the losses bias the latency distribution?
#
# At <=256 KB only 170-179 of 200 measured buffers arrive.  Every published p50
# is therefore a median over survivors.  That is only comparable to DAQiri's
# (which drops nothing) if the losses are independent of latency.  If instead
# the ring sheds buffers exactly when the server is behind, the survivors are a
# biased, friendlier sample and the "parity at small sizes" claim is inflated.
#
# Two things distinguish the cases, and this script measures both:
#
#   1. Gap structure.  Independent loss shows up as many isolated single drops
#      spread across the run (mean run length ~1).  Overrun shows up as a few
#      long bursts, or a cluster at the very start while the ring fills.
#
#   2. Load sensitivity.  If drops are caused by the server falling behind,
#      slowing the client down (--pace-us) must reduce them, and making the
#      server faster (--zc-align) must also reduce them.  If loss is random
#      (a fixed per-message probability) neither knob moves it.
#
# Arms x pace is a 2x2: base/e2 crossed with the normal and a relaxed pace.
set -u
cd "$HOME/daqiri_gpu" || exit 1
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"

SERVER=build_grpc/bench_grpc_server
CLIENT=build_grpc/bench_grpc_client
SIZES="${SIZES:-4096 65536 1048576}"
ARMS="${ARMS:-base e2}"
PACES="${PACES:-400 2000}"
N=200; W=50; PORT=50102

clean_shmem () {
    pkill -9 -f bench_grpc_server 2>/dev/null
    pkill -9 -f bench_grpc_client 2>/dev/null
    rm -rf /tmp/iceoryx2 2>/dev/null
    rm -f /dev/shm/iox2_* 2>/dev/null
    sleep 1
}

arm_flags () {
    case "$1" in
        base) echo "--no-zc-align" ;;
        e2)   echo "--zc-align" ;;
    esac
}

printf "%-5s %-6s %-8s %-6s %-6s %-8s %-6s %-9s %-9s %-9s\n" \
  "arm" "pace" "size_KB" "recv" "miss" "miss_pct" "gaps" "run_len" "e2e_p50" "e2e_p99"
echo "------------------------------------------------------------------------------------"

clean_shmem
for S in $SIZES; do
  KB=$(( S * 4 / 1024 ))
  for P in $PACES; do
    for ARM in $ARMS; do
      FLAGS=$(arm_flags "$ARM")
      CSV="data/drop_${ARM}_${P}_${S}.csv"
      LOG="/tmp/drop_${ARM}_${P}_${S}.log"
      clean_shmem
      rm -f "$CSV"
      timeout 180 $SERVER --port $PORT --bufsize $S --n-buffers $N --warmup $W \
          --out "$CSV" --transport shmem --one-shot --zero-copy \
          $FLAGS >"$LOG" 2>&1 &
      SPID=$!
      sleep 4
      timeout 160 taskset -c 11 $CLIENT --server "localhost:$PORT" --transport shmem \
          --bufsize $S --n-buffers $N --warmup $W --pace-us $P >>"$LOG" 2>&1
      wait $SPID 2>/dev/null

      recv=$(awk '/^  received/{print $3; exit}' "$LOG")
      miss=$(awk '/^  missing  /{print $3; exit}' "$LOG")
      mpct=$(awk '/^  missing  /{gsub(/[()]/,"",$4); print $4; exit}' "$LOG")
      gaps=$(awk '/^  gap events/{print $4; exit}' "$LOG")
      rlen=$(awk '/^  mean run length/{print $5; exit}' "$LOG")
      e2e50=$(awk '/E2E p50/{print $4; exit}' "$LOG")
      e2e99=$(awk '/E2E p50/{print $8; exit}' "$LOG")

      printf "%-5s %-6s %-8s %-6s %-6s %-8s %-6s %-9s %-9s %-9s\n" \
        "$ARM" "$P" "$KB" "${recv:-NA}" "${miss:-NA}" "${mpct:-NA}" \
        "${gaps:-NA}" "${rlen:-1}" "${e2e50:-NA}" "${e2e99:-NA}"
    done
  done
done

echo
echo "==== missing-seq detail (position of the holes) ===="
for S in $SIZES; do
  for P in $PACES; do
    for ARM in $ARMS; do
      LOG="/tmp/drop_${ARM}_${P}_${S}.log"
      [ -f "$LOG" ] || continue
      echo "--- ${ARM} pace=${P} size=$(( S * 4 / 1024 ))KB ---"
      awk '/^  seq range/{print} /^  missing seqs/{print}' "$LOG"
    done
  done
done
clean_shmem
