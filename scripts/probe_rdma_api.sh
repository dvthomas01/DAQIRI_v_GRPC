#!/usr/bin/env bash
set -u
D=/home/nitest/daqiri
echo "======== 1. RDMAOpCode enum + rdma api signatures in daqiri.h ========"
grep -nE "RDMAOpCode|rdma_set_header|rdma_get_opcode|rdma_connect_to_server|rdma_get_server_conn_id|is_tx_burst_available|free_tx_burst|free_all_packets_and_burst_rx|get_packet_ptr|get_rx_burst|set_packet_lengths|create_tx_burst_params|get_tx_packet_burst|send_tx_burst" \
  "$D/include/daqiri/daqiri.h" 2>/dev/null | head -60
echo
echo "======== 2. does get_packet_ptr work on a RECEIVE completion (RDMA engine)? ========"
grep -nE "get_packet_ptr|RECEIVE|recv.*buf|completion|wc\.|imm_data|get_rx_burst|payload|opcode" \
  "$D/src/engines/rdma/daqiri_rdma_engine.cpp" 2>/dev/null | grep -iE "get_packet_ptr|receive|completion|get_rx_burst|payload|recv_buf" | head -30
echo
echo "======== 3. RdmaEngine::get_packet_ptr impl ========"
sed -n '/RdmaEngine::get_packet_ptr/,/^}/p' "$D/src/engines/rdma/daqiri_rdma_engine.cpp" 2>/dev/null | head -20
echo
echo "======== 4. RDMAOpCode enum definition ========"
grep -rnE "enum.*RDMAOpCode|SEND|RECEIVE|WRITE|READ" "$D/include/daqiri/"*.h 2>/dev/null | grep -iE "RDMAOpCode|= 0|SEND|RECEIVE" | head -20
echo "DONE"
