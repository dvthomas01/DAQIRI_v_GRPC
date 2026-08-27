#!/usr/bin/env bash
set -u
D=/home/nitest/daqiri
echo "======== 1. where are rdma_ free functions declared? ========"
grep -rnE "rdma_set_header|rdma_get_opcode|rdma_connect_to_server|rdma_get_server_conn_id|is_tx_burst_available|free_tx_burst" \
  "$D/include/" 2>/dev/null | grep -iE "Status|void|bool|rdma_" | head -40
echo
echo "======== 2. headers rdma_bench.cpp includes ========"
grep -nE "#include" "$D/examples/rdma_bench.cpp" 2>/dev/null | head
echo
echo "======== 3. RECEIVE completion: is payload ptr put into completion burst pkts? (lines 590-640, 820-870) ========"
sed -n '588,645p' "$D/src/engines/rdma/daqiri_rdma_engine.cpp"
echo "----- 820-875 -----"
sed -n '820,875p' "$D/src/engines/rdma/daqiri_rdma_engine.cpp"
echo "DONE"
