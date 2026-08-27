#!/usr/bin/env bash
# Read-only probe: does DAQiri's socket API support roce:// in a single process,
# and is same-eswitch RC loopback possible without root/netns?
set -u
D=/home/nitest/daqiri
echo "======== 1. daqiri.h socket/roce API surface ========"
grep -nE "socket_connect_to_server|socket_get_server_conn_id|socket_get_port_queue|roce|RoCE|RDMA|rdma|transport_mode|scheme" \
    "$D/include/daqiri/daqiri.h" 2>/dev/null | head -60

echo
echo "======== 2. how the socket engine parses the address scheme ========"
grep -rnE "roce://|tcp://|parse_scheme|scheme ==|starts_with\(\"roce|transport_mode|RC\b|ibv_|rdma_cm" \
    "$D/src/engines/socket/" 2>/dev/null | head -40

echo
echo "======== 3. is there a single-process (non-netns) roce example? ========"
ls -1 "$D/examples/" 2>/dev/null | grep -iE "roce|rdma|loopback|netns" | head -40

echo
echo "======== 4. roce_config keys expected in YAML ========"
grep -rnE "roce_config|transport_mode|gid_index|rx_depth|tx_depth|local_addr|remote_addr" \
    "$D/examples/"*.yaml 2>/dev/null | head -40

echo
echo "======== 5. can we create a QP as nitest (no root)? ========"
which ibv_devices ibv_devinfo 2>/dev/null
ibv_devices 2>/dev/null | head
echo "--- rdma link states ---"
rdma link show 2>/dev/null | head

echo
echo "======== 6. existing pipeline binary + config on Spark ========"
ls -la /home/nitest/daqiri_gpu/daqiri/ 2>/dev/null | grep -iE "config|bench" | head
echo "--- current config_pipeline.yaml transport lines ---"
grep -nE "mode:|tcp://|roce://|max_payload_size|buf_size|num_bufs|engine" \
    /home/nitest/daqiri_gpu/daqiri/config_pipeline.yaml 2>/dev/null | head -40
echo "DONE"
