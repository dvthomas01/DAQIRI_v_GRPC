#!/usr/bin/env bash
set -u
echo "======== 1. IPs currently assigned to RoCE netdevs ========"
for d in enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1; do
  ip -br addr show "$d" 2>/dev/null
done
echo
echo "======== 2. physical cabling / link partner (which port <-> which) ========"
for d in enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1; do
  spd=$(cat /sys/class/net/$d/speed 2>/dev/null)
  car=$(cat /sys/class/net/$d/carrier 2>/dev/null)
  echo "$d: carrier=$car speed=${spd}Mb/s"
done
echo
echo "======== 3. daqiri_bench_rdma binary present? ========"
find /home/nitest/daqiri -maxdepth 4 -name 'daqiri_bench_rdma*' -type f 2>/dev/null | head
ls -la /home/nitest/daqiri/build/*/daqiri_bench_rdma 2>/dev/null | head
echo
echo "======== 4. does the socket engine map a programmatic addr -> interface? ========"
grep -nE "connect_to_server|get_server_conn_id|find.*interface|interface.*addr|by_addr|roce://|local_addr|match" \
  /home/nitest/daqiri/src/engines/socket/daqiri_socket_engine.cpp 2>/dev/null | head -40
echo
echo "======== 5. how daqiri_init selects engine per interface (socket vs rdma) ========"
grep -rnE "roce://|tcp://|udp://|scheme|make_unique<RdmaEngine>|roce_engine_|use_roce|is_roce" \
  /home/nitest/daqiri/src/engines/socket/daqiri_socket_engine.cpp 2>/dev/null | head -30
echo
echo "======== 6. public API for roce in daqiri.h (what my bench must call) ========"
grep -nE "connect_to_server|get_server_conn_id|get_port_queue|socket_|rdma_|roce" \
  /home/nitest/daqiri/include/daqiri/daqiri.h 2>/dev/null | head -60
echo "DONE"
