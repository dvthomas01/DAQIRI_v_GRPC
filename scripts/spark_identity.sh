#!/usr/bin/env bash
# Collect identifying information about this Spark unit.
echo "=== hostname / FQDN ==="
hostname
hostname -f 2>/dev/null

echo "=== OS ==="
if [ -r /etc/os-release ]; then . /etc/os-release; echo "$PRETTY_NAME"; fi
uname -srm

echo "=== product / vendor / serial (DMI) ==="
cat /sys/class/dmi/id/sys_vendor 2>/dev/null
cat /sys/class/dmi/id/product_name 2>/dev/null
cat /sys/class/dmi/id/board_name 2>/dev/null
cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "(serial hidden; needs root)"

echo "=== corp LAN (enP7s7) ==="
ip -4 addr show enP7s7 2>/dev/null | grep 'inet '
echo -n "MAC: "; cat /sys/class/net/enP7s7/address 2>/dev/null

echo "=== RoCE port (enp1s0f1np1) ==="
ip -4 addr show enp1s0f1np1 2>/dev/null | grep 'inet '
echo -n "MAC: "; cat /sys/class/net/enp1s0f1np1/address 2>/dev/null

echo "=== CPU ==="
grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //'
nproc

echo "=== memory ==="
grep MemTotal /proc/meminfo 2>/dev/null

echo "=== GPU ==="
nvidia-smi --query-gpu=name,serial,uuid,driver_version,memory.total --format=csv,noheader 2>/dev/null
