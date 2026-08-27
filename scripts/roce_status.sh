#!/usr/bin/env bash
# Quick RoCE readiness probe on Spark.
set -u

echo "=== RDMA devices ==="
ibv_devices 2>/dev/null

echo
echo "=== port/link state per device ==="
for d in rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1; do
  echo "--- $d ---"
  ibv_devinfo -d "$d" 2>/dev/null | grep -Ei "state:|rate:|link_layer|phys_state" || echo "  (no devinfo)"
done

echo
echo "=== ethernet ifaces (name/state/mac) ==="
ip -br link show 2>/dev/null | grep -Ei "enp1s0f|roce" || ip -br link show 2>/dev/null

echo
echo "=== ip addresses on those ifaces ==="
ip -br addr show 2>/dev/null | grep -Ei "enp1s0f|192.168.10|10.250" || echo "  (none)"

echo
echo "=== network namespaces ==="
ip netns list 2>/dev/null || echo "  (none)"

echo
echo "=== loopback setup script present? ==="
ls -1 /home/nitest/daqiri/scripts/ 2>/dev/null | grep -Ei "netns|wire_loopback|run_spark_bench|gen_spark" || echo "  (not in daqiri/scripts)"
find /home/nitest/daqiri -maxdepth 3 -iname '*wire_loopback*' -o -iname 'run_spark_bench*' 2>/dev/null | head
