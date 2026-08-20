#!/usr/bin/env bash
# Assign the RoCE static IP on the PXI and identify the Spark-side port via ARP.
IF=enp117s0
echo "=== before ==="
ip -br addr show dev $IF
# drop the stale link-local, set the 50G subnet static IP (runtime only, not persisted)
ip addr flush dev $IF
ip addr add 192.168.20.2/24 dev $IF
ip link set $IF up
echo "=== after ==="
ip -br addr show dev $IF
echo "=== ping Spark 192.168.20.1 (owned by Spark enp1s0f0np0) ==="
ping -c 3 -W 1 192.168.20.1 || true
echo "=== which Spark MAC answered for .20.1? ==="
ip neigh show 192.168.20.1
echo "  [Spark: 4c:bb:47:2e:ac:6a=enp1s0f0np0   4c:bb:47:2e:ac:6e=enP2p1s0f0np0]"
echo DONE_SETIP
