#!/usr/bin/env bash
# Find the Spark on the lab subnet by MAC, from the PXI.
#
# Why this exists: DNS and the ssh config both hold a DHCP lease address that
# can go stale, and a stale ARP entry will happily report the Spark as alive
# when nothing is at that address. `ip neigh` must be flushed before it is
# trusted. This sweeps the /24 and reports whoever answers with the Spark's
# management MAC, which is the only identifier that does not move.
set -u

IFACE="${1:-eno0}"
PREFIX="${2:-10.198.65}"
SPARK_MAC="4c:bb:47:2e:ac:69"

echo "=== flushing neighbour cache on $IFACE so nothing stale is believed ==="
ip neigh flush dev "$IFACE" 2>/dev/null || true

echo "=== sweeping ${PREFIX}.1-254 ==="
for i in $(seq 1 254); do
    ping -c1 -W1 "${PREFIX}.${i}" >/dev/null 2>&1 &
done
wait

echo "=== hosts answering with an NVIDIA OUI (4c:bb:47) ==="
ip neigh | grep -i '4c:bb:47' || echo "  none"

echo "=== our Spark specifically ($SPARK_MAC) ==="
if ip neigh | grep -i "$SPARK_MAC"; then
    echo "  FOUND"
else
    echo "  NOT PRESENT on ${PREFIX}.0/24 - the box is off the network, not merely at a new address"
fi
