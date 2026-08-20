#!/usr/bin/env bash
# Restore the PXI's RoCE address and re-read the GID index.
#
# Run as root on the PXI. Idempotent: if the address is already there,
# `ip addr add` reports EEXIST and we carry on.
#
# Why this exists: 192.168.20.2/24 and mtu 9000 are runtime-only. They are lost
# on a PXI reboot AND on a carrier flap, which is what a Spark power cycle looks
# like from this end. Observed 2026-08-20: the PXI had 13 days of uptime and had
# still reverted to a 169.254/16 link-local address after the Spark was rebooted.
#
# The GID index is NOT stable. It follows the address, so it must be read after
# the address is restored, never hardcoded from memory.

set -u

IFACE=${1:-enp117s0}
ADDR=${2:-192.168.20.2/24}
MTU=${3:-9000}

echo "=== before ==="
ip -4 -o addr show "$IFACE" || true

echo
echo "=== applying $ADDR and mtu $MTU on $IFACE ==="
ip addr add "$ADDR" dev "$IFACE" 2>&1 || echo "  (add returned non-zero; EEXIST is fine)"
ip link set dev "$IFACE" mtu "$MTU" 2>&1 || echo "  (mtu set returned non-zero)"
ip link set dev "$IFACE" up 2>&1 || true

echo
echo "=== after ==="
ip -4 -o addr show "$IFACE"
ip -o link show "$IFACE"

echo
echo "=== RoCE v2 IPv4 GID indices (read, do not assume) ==="
for d in /sys/class/infiniband/*; do
  dev=$(basename "$d")
  echo "  $dev:"
  for i in 0 1 2 3 4 5 6 7; do
    g="$d/ports/1/gids/$i"
    [ -r "$g" ] || continue
    gid=$(cat "$g" 2>/dev/null)
    case "$gid" in
      0000:0000:0000:0000:0000:0000:0000:0000) continue ;;
    esac
    t="$d/ports/1/gid_attrs/types/$i"
    typ=$(cat "$t" 2>/dev/null || echo "?")
    case "$gid" in
      0000:0000:0000:0000:0000:ffff:*) echo "    index $i  $typ  $gid  <-- IPv4-mapped" ;;
    esac
  done
done

echo
echo "=== reachability to the Spark's RoCE address ==="
ping -c 3 -W 2 192.168.20.1 2>&1 | tail -4
