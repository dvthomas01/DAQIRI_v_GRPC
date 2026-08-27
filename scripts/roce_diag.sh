#!/usr/bin/env bash
echo '=== all net ifaces: state/carrier/speed/mac ==='
for d in /sys/class/net/*; do
  n=$(basename "$d")
  [ "$n" = lo ] && continue
  sp=$(cat "$d/speed" 2>/dev/null)
  car=$(cat "$d/carrier" 2>/dev/null)
  ops=$(cat "$d/operstate" 2>/dev/null)
  mac=$(cat "$d/address" 2>/dev/null)
  printf '%-16s state=%-6s carrier=%-2s speed=%-8s mac=%s\n' "$n" "$ops" "$car" "${sp:-NA}" "$mac"
done
echo
echo '=== RoCE iface enp1s0f1np1 detail ==='
ip -br addr show enp1s0f1np1
echo
echo '=== RDMA devices ==='
ibv_devices 2>/dev/null || echo 'ibv_devices not available'
echo
echo '=== ibstat (port state/rate) ==='
ibstat 2>/dev/null | grep -E 'CA |State|Rate|Physical|Link layer' || echo 'ibstat not available'
echo
echo '=== ARP neighbor on RoCE subnet ==='
ip neigh show dev enp1s0f1np1
echo
echo '=== ping PXI 192.168.10.2 ==='
ping -c 3 -W 1 192.168.10.2
echo
echo '=== ethtool port type / modes (both active RoCE ports) ==='
for i in enp1s0f1np1 enP2p1s0f1np1; do
  echo "### $i"
  ethtool "$i" 2>/dev/null | grep -Ei 'Supported link modes|Advertised link modes|Speed|Duplex|Port:|Auto-negotiation|Link detected'
  echo
done
