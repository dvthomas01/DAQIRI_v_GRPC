#!/usr/bin/env bash
# Go/no-go probe for the RoCE FFT headline on Spark.
set -u

echo "=== sudo without password? ==="
if sudo -n true 2>/dev/null; then echo "  sudo -n: YES (passwordless root available)"; else echo "  sudo -n: NO"; fi

echo
echo "=== running inside a privileged container? ==="
grep -qE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null && echo "  container: likely YES" || echo "  container: likely NO (bare host)"
echo "  cap check (net_admin via ip netns add dry): "
ip netns add dq_probe_test 2>&1 && { echo "   netns add OK"; ip netns del dq_probe_test 2>/dev/null; } || echo "   netns add DENIED"

echo
echo "=== loopback setup scripts available ==="
ls -1 /home/nitest/daqiri/scripts/ 2>/dev/null | grep -Ei "rdma_loopback|wire_loopback|netns" || echo "  (none matched)"

echo
echo "=== which ports report carrier/link detected (cabled) ==="
for IF in enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1; do
  ld=$(ethtool "$IF" 2>/dev/null | grep -i "link detected" | awk '{print $NF}')
  spd=$(ethtool "$IF" 2>/dev/null | grep -i "speed" | awk '{print $NF}')
  echo "  $IF: link_detected=${ld:-n/a} speed=${spd:-n/a}"
done

echo
echo "=== how the socket API maps addr->interface (daqiri.h signatures) ==="
grep -nE "socket_connect_to_server|socket_get_server_conn_id|roce|transport_mode" /home/nitest/daqiri/include/daqiri/daqiri.h 2>/dev/null | head -20 || echo "  (daqiri.h not at that path)"
find /home/nitest/daqiri -name daqiri.h 2>/dev/null | head
