#!/usr/bin/env bash
set -u
D=/home/nitest/daqiri
echo "======== 1. daqiri_bench_rdma usage/flags ========"
"$D/build/examples/daqiri_bench_rdma" --help 2>&1 | head -40
echo
echo "======== 2. full netns yaml (memory_regions + roce + depths structure) ========"
sed -n '1,140p' "$D/examples/daqiri_bench_rdma_tx_rx_spark_netns.yaml"
echo
echo "======== 3. does RdmaEngine support same-IP / same-device loopback? ========"
grep -nE "loopback|same.?dev|self|src_addr == |lo\b|127\.|resolve_addr|bind_addr|listen|rdma_bind" \
  "$D/src/engines/rdma/daqiri_rdma_engine.cpp" 2>/dev/null | head -30
echo "DONE"
