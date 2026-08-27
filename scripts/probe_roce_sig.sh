#!/usr/bin/env bash
set -u
H=/home/nitest/daqiri/include/daqiri/common.h
echo "===== rdma_connect_to_server ====="; grep -n "rdma_connect_to_server" "$H"
echo "===== rdma_get_server_conn_id ====="; grep -n "rdma_get_server_conn_id" "$H"
echo "===== rdma_set_header ====="; grep -n "rdma_set_header" "$H"
echo "===== rdma_get_opcode ====="; grep -n "rdma_get_opcode" "$H"
echo "===== is_tx_burst_available ====="; grep -n "is_tx_burst_available" "$H"
echo "===== free_tx_burst / free_tx_metadata ====="; grep -n "free_tx_burst\|free_tx_metadata" "$H"
echo "===== set_packet_lengths ====="; grep -n "set_packet_lengths" "$H"
echo "===== RDMAOpCode enum ====="; grep -rn "enum class RDMAOpCode\|SEND\|RECEIVE" /home/nitest/daqiri/include/daqiri/types.h | head
echo "===== signatures (context) ====="
grep -n -A1 "rdma_connect_to_server\|rdma_get_server_conn_id\|rdma_set_header\|rdma_get_opcode" "$H"
echo DONE
