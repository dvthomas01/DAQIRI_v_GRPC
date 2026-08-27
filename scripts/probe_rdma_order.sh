#!/usr/bin/env bash
set -u
B=/home/nitest/daqiri/examples/rdma_bench.cpp
echo "===== main(): thread startup order + sleeps ====="
grep -nE "server_thread|client_thread|rdma_worker|sleep|get_server_conn_id|connect_to_server|join|is_server|mode" "$B" | head -60
echo
echo "===== rdma_worker: connection setup (first 60 lines of the fn) ====="
awk '/void[ ]+rdma_worker|rdma_worker\(/{f=1} f{print NR": "$0} f&&/^}/{c++; if(c>0 && NR>start+5){}}' "$B" | head -5
# print the connection-establishment region
grep -n "rdma_get_server_conn_id\|rdma_connect_to_server\|is_server\|conn_id\|sleep\|accept\|Established\|established" "$B" | head -40
echo DONE
