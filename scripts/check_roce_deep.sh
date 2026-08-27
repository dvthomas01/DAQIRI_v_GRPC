#!/usr/bin/env bash
# Deeper RoCE diagnosis: which ports have a real link partner, RDMA port state,
# who is physically on the other end (LLDP), and whether the PXI answers on the
# 50G subnet (192.168.20.x), not the dead 1G one (192.168.10.x).
echo "=================== ALL NET INTERFACES ==================="
for IF in $(ls /sys/class/net | grep -E 'enp|enP'); do
    CA=$(cat /sys/class/net/$IF/carrier 2>/dev/null)
    OP=$(cat /sys/class/net/$IF/operstate 2>/dev/null)
    SP=$(cat /sys/class/net/$IF/speed 2>/dev/null)
    MAC=$(cat /sys/class/net/$IF/address 2>/dev/null)
    IPA=$(ip -4 -o addr show dev $IF 2>/dev/null | awk '{print $4}' | paste -sd, -)
    printf "  %-16s carrier=%s oper=%-6s speed=%-7s mac=%s ip=%s\n" \
        "$IF" "${CA:-NA}" "${OP:-NA}" "${SP:-NA}Mb" "$MAC" "${IPA:-none}"
done

echo
echo "=================== ethtool link detail (all 4 RoCE ports) ==================="
for IF in enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1; do
    echo "--- $IF ---"
    ethtool $IF 2>/dev/null | grep -E 'Speed|Duplex|Port:|Link detected'
done

echo
echo "=================== RDMA link state (PORT_ACTIVE = physical link up) ==================="
rdma link show 2>/dev/null || echo "  (rdma tool not available)"
echo "--- ibstat (state + phys state + rate per RoCE dev) ---"
for D in rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1; do
    echo "[$D]"
    ibstat $D 2>/dev/null | grep -E 'State|Physical state|Rate|Link layer' || echo "  (ibstat n/a)"
done

echo
echo "=================== LLDP: who is physically on the other end ==================="
if command -v lldpctl >/dev/null 2>&1; then
    lldpctl 2>/dev/null | grep -E 'Interface|SysName|PortDescr|MgmtIP|ChassisID' || echo "  (lldpctl: no neighbors)"
elif command -v lldptool >/dev/null 2>&1; then
    for IF in enp1s0f0np0 enP2p1s0f0np0; do
        echo "--- $IF ---"; lldptool -i $IF -t -n 2>/dev/null | head -20
    done
else
    echo "  (no LLDP tool installed)"
fi

echo
echo "=================== Find the PXI on the 50G subnet (192.168.20.x) ==================="
echo "[quick ping sweep 192.168.20.2..20 + .100 .101 .200 (from 192.168.20.1)]"
for n in 2 3 4 5 6 7 8 9 10 20 100 101 200; do
    ping -c1 -W1 192.168.20.$n >/dev/null 2>&1 && echo "  ALIVE: 192.168.20.$n"
done
echo "[also retry the old 1G PXI IP 192.168.10.2]"
ping -c1 -W1 192.168.10.2 >/dev/null 2>&1 && echo "  ALIVE: 192.168.10.2" || echo "  192.168.10.2 no reply"
echo "[ARP / neighbor table after sweep]"
ip neigh show | grep -E '192.168.20|192.168.10' || echo "  (no RoCE neighbors learned on either subnet)"
echo "DONE_DEEP_CHECK"
