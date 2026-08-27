#!/usr/bin/env bash
# PXI-side RoCE identification (read-only).
echo "=================== links + MACs ==================="
ip -br link
echo
echo "=================== enp117s0 speed / link ==================="
ethtool enp117s0 2>/dev/null | grep -E 'Speed|Duplex|Port:|Link detected'
echo
echo "=================== PCIe: is enp117s0 a ConnectX? ==================="
lspci 2>/dev/null | grep -iE 'mellanox|connectx|ethernet' || echo "  (lspci n/a)"
echo
echo "=================== RDMA devices / link ==================="
rdma link show 2>/dev/null || echo "  (rdma tool n/a)"
ibv_devices 2>/dev/null || echo "  (ibv_devices n/a)"
echo
echo "=================== Who is on the other end? (peer MAC) ==================="
echo "[Spark 50G MACs for reference: enp1s0f0np0=4c:bb:47:2e:ac:6a  enP2p1s0f0np0=4c:bb:47:2e:ac:6e]"
ip neigh show dev enp117s0
if command -v lldpctl >/dev/null 2>&1; then lldpctl 2>/dev/null | grep -iE 'Interface|ChassisID|SysName|PortID|MgmtIP'
elif command -v lldptool >/dev/null 2>&1; then lldptool -i enp117s0 -t -n 2>/dev/null | head -20
else echo "  (no LLDP tool)"; fi
echo
echo "=================== Am I root here? ==================="
id -u
echo "DONE_PXI_CHECK"
