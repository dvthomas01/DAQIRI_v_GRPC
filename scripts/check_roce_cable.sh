#!/usr/bin/env bash
# Check RoCE cabling Spark <-> PXI: which ports have link, at what speed, and
# whether the PXI RoCE IP answers.
echo "=================== RoCE PORT LINK / SPEED ==================="
for IF in enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1; do
    SP=$(cat /sys/class/net/$IF/speed 2>/dev/null)
    CA=$(cat /sys/class/net/$IF/carrier 2>/dev/null)
    OP=$(cat /sys/class/net/$IF/operstate 2>/dev/null)
    IPA=$(ip -4 -o addr show dev $IF 2>/dev/null | awk '{print $4}' | paste -sd, -)
    printf "  %-16s carrier=%s oper=%-6s speed=%-8s ip=%s\n" \
        "$IF" "${CA:-NA}" "${OP:-NA}" "${SP:-NA}Mb" "${IPA:-none}"
done
echo
echo "=================== ethtool detail (f0=50G pair, f1=PXI) ==================="
for IF in enp1s0f0np0 enp1s0f1np1; do
    echo "--- $IF ---"
    ethtool $IF 2>/dev/null | grep -E 'Speed|Duplex|Link detected|Port:'
done
echo
echo "=================== RDMA devices ==================="
ibv_devices 2>/dev/null
echo
echo "=================== PXI reachability over RoCE link ==================="
echo "[ping 192.168.10.2 (PXI RoCE, expected on f1 subnet)]"
ping -c 2 -W 2 192.168.10.2 2>&1 | tail -3
echo "[arping on enp1s0f1np1 -> 192.168.10.2]"
timeout 5 arping -c 2 -I enp1s0f1np1 192.168.10.2 2>&1 | tail -4 || echo "  (arping unavailable or no reply)"
echo "[neighbor table]"
ip neigh show | grep -E '192.168.10|192.168.20' || echo "  (no RoCE neighbors learned)"
echo "DONE_CABLE_CHECK"
