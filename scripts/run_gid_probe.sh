#!/usr/bin/env bash
# Build and run the GID probe. Arg 1 is the RDMA device name.
set -u
DEV="${1:-}"
PEER="${2:-}"
# Run from wherever gid_probe.cc actually is: the Spark mirror, the PXI's
# rdma_p2, or the current directory if the script was copied alongside it.
for d in "$PWD" "$HOME/daqiri_gpu/rdma" "$HOME/rdma_p2" "$HOME/rdma"; do
  [ -f "$d/gid_probe.cc" ] && cd "$d" && break
done
[ -f gid_probe.cc ] || { echo "gid_probe.cc not found"; exit 1; }
echo "### pwd: $PWD"
g++ -O2 -std=c++20 -I. -o /tmp/gid_probe gid_probe.cc -libverbs 2>&1 | tail -30
echo "BUILD_EXIT=$?"
[ -x /tmp/gid_probe ] || { echo "no binary"; exit 1; }
/tmp/gid_probe "$DEV" "$PEER"
echo "RUN_EXIT=$?"
echo
echo "### ground truth from the GID table ###"
for i in $(seq 0 9); do
  t="/sys/class/infiniband/$DEV/ports/1/gid_attrs/types/$i"
  g="/sys/class/infiniband/$DEV/ports/1/gids/$i"
  [ -f "$g" ] || continue
  printf "  %d  %-10s %s\n" "$i" "$(cat "$t" 2>/dev/null)" "$(cat "$g" 2>/dev/null)"
done
echo
echo "### the address that index follows ###"
ip -4 addr show | grep -A0 'inet 192.168.20' || echo "  no 192.168.20.x address"
