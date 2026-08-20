#!/usr/bin/env bash
# Post-reboot RoCE state check. Run on either machine; it reports what it finds
# rather than assuming which end it is on.
#
# Why this exists: the RoCE addresses and the 9000 MTU are runtime-only on the
# PXI and are lost on reboot, and a queue pair silently negotiates DOWN to the
# smaller active_mtu of the two ends. That costs about 5% of bandwidth with no
# error reported anywhere, so an MTU mismatch is worth checking explicitly
# rather than discovering it in a sweep.
set -u

echo "=== host ==="
hostname

echo
echo "=== RoCE netdevs (expect 192.168.20.1 on Spark, .2 on PXI, mtu 9000) ==="
for d in enp1s0f0np0 enp117s0; do
    if ip link show "$d" >/dev/null 2>&1; then
        ip -4 addr show "$d" | sed -n '1p;/inet /p'
    fi
done

echo
echo "=== ibverbs devices ==="
ls /sys/class/infiniband/ 2>/dev/null || echo "  none"

echo
echo "=== port state and rate ==="
for dev in /sys/class/infiniband/*; do
    [ -e "$dev/ports/1/state" ] || continue
    printf '  %-14s state=%-14s phys=%-16s rate=%s\n' \
        "$(basename "$dev")" \
        "$(cat "$dev/ports/1/state" 2>/dev/null)" \
        "$(cat "$dev/ports/1/phys_state" 2>/dev/null)" \
        "$(cat "$dev/ports/1/rate" 2>/dev/null)"
done

echo
echo "=== active_mtu (NOT in sysfs; both ends must agree or the QP negotiates down) ==="
if command -v ibv_devinfo >/dev/null 2>&1; then
    ibv_devinfo 2>/dev/null | grep -E "hca_id|active_mtu|state:" | sed 's/^/  /'
else
    echo "  ibv_devinfo not on PATH; cannot read active_mtu here"
    echo "  netdev MTU is the input to it, and is shown above"
fi

echo
echo "=== RoCE v2 IPv4 GID indices (read them, do not assume; they shift) ==="
for dev in /sys/class/infiniband/*; do
    [ -d "$dev/ports/1/gid_attrs/types" ] || continue
    echo "  $(basename "$dev"):"
    for i in $(seq 0 7); do
        t=$(cat "$dev/ports/1/gid_attrs/types/$i" 2>/dev/null) || continue
        g=$(cat "$dev/ports/1/gids/$i" 2>/dev/null)
        case "$g" in
            0000:0000:0000:0000:0000:ffff:*) echo "    index $i  $t  $g  <-- IPv4-mapped" ;;
        esac
    done
done
