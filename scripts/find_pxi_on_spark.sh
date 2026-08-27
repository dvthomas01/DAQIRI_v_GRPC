#!/usr/bin/env bash
# Discover NI devices (PXIs) on Spark's corporate subnet and probe the candidate.
set -u

SUBNET="10.198.65"
CAND="10.198.65.114"
IFACE="enP7s7"

echo "=== ping-sweep ${SUBNET}.0/24 (populate ARP) ==="
for i in $(seq 1 254); do
  ping -c1 -W1 "${SUBNET}.${i}" >/dev/null 2>&1 &
done
wait
echo "sweep done"

echo "=== National Instruments (00:80:2f) MAC neighbors ==="
ip neigh show dev "${IFACE}" | grep -i '00:80:2f' || echo "(none with NI OUI)"

echo "=== all reachable neighbors on ${IFACE} ==="
ip neigh show dev "${IFACE}" | grep -iE 'REACHABLE|STALE'

echo "=== reverse DNS for candidate ${CAND} ==="
getent hosts "${CAND}" || echo "(no PTR record)"

echo "=== port probe on ${CAND} (22 ssh, 80/443 web, 3580 NI-sysapi) ==="
for p in 22 80 443 3580; do
  if timeout 2 bash -c "echo > /dev/tcp/${CAND}/${p}" 2>/dev/null; then
    echo "port ${p} OPEN"
  else
    echo "port ${p} closed"
  fi
done
