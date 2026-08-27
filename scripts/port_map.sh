#!/usr/bin/env bash
# Map the two 50G QSFP faceplate ports to interface names.
echo "=================== PCIe location of each 50G port ==================="
for IF in enp1s0f0np0 enP2p1s0f0np0; do
    PCI=$(readlink -f /sys/class/net/$IF/device 2>/dev/null | sed 's#.*/##')
    PPN=$(cat /sys/class/net/$IF/phys_port_name 2>/dev/null)
    printf "  %-16s pci=%s phys_port_name=%s\n" "$IF" "${PCI:-NA}" "${PPN:-NA}"
done
echo
echo "--- lspci for the ConnectX / Ethernet controllers ---"
lspci 2>/dev/null | grep -iE 'ethernet|connectx|mellanox|network' || echo "  (lspci n/a)"
echo
echo "=================== Can we blink the port LED without root? ==================="
echo "[trying: ethtool -p enp1s0f0np0 2  (2-second identify)]"
timeout 6 ethtool -p enp1s0f0np0 2 2>&1; RC=$?
if [ $RC -eq 0 ]; then echo "  LED blink: PERMITTED (no root needed)"; else echo "  LED blink rc=$RC (permission or timeout)"; fi
echo "DONE_PORTMAP"
