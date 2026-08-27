#!/usr/bin/env bash
# Disambiguate the topology: recent link-up events, which ports have a DAC
# module physically seated, and whether we can assign a test IP (need root).
echo "=================== Recent link-up / carrier events (dmesg) ==================="
dmesg 2>/dev/null | grep -iE 'enp1s0f0|enP2p1s0f0|link up|link down|Link up|NIC Link' | tail -25 \
    || echo "  (dmesg not readable without root, or no matches)"

echo
echo "=================== Transceiver / DAC seated? (ethtool -m) ==================="
for IF in enp1s0f0np0 enP2p1s0f0np0; do
    echo "--- $IF ---"
    ethtool -m $IF 2>&1 | grep -iE 'Identifier|Vendor name|Vendor PN|Vendor SN|Cable|Length|Connector' | head -8 \
        || echo "  (no module info / needs root)"
done

echo
echo "=================== Can we assign IPs (sudo)? ==================="
sudo -n true 2>/dev/null && echo "  passwordless sudo: YES" || echo "  passwordless sudo: NO"

echo
echo "=================== Peer MAC on each 50G port via L2 probe ==================="
# Send a broadcast ping on each 50G port and see what MAC(s) reply at L2, which
# reveals whether the two ports hear EACH OTHER (loop) or a distinct PXI.
for IF in enp1s0f0np0 enP2p1s0f0np0; do
    echo "--- $IF broadcast arp probe ---"
    ping -c2 -W1 -b -I $IF 192.168.20.255 >/dev/null 2>&1
done
ip neigh show | grep -E 'enp1s0f0np0|enP2p1s0f0np0' || echo "  (no L2 neighbors seen)"
echo "--- Spark's own RoCE MACs for reference ---"
echo "  enp1s0f0np0 = 4c:bb:47:2e:ac:6a"
echo "  enP2p1s0f0np0 = 4c:bb:47:2e:ac:6e"
echo "DONE_TOPO_CHECK"
