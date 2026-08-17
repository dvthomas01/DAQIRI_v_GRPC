#!/usr/bin/env bash
# Find the DGX Spark on the management subnet when DNS is stale.
#
# The Spark's management NIC (enP7s7) is on DHCP and the corp DNS record for
# spark-ac69.ni.corp.natinst.com does not always follow it. When that happens
# the box looks dead: the name resolves to an address nothing answers on.
#
# Run this ON THE PXI (10.198.65.118), which shares the L2 subnet:
#     scp scripts/find_spark.sh root@10.198.65.118:/tmp/
#     ssh root@10.198.65.118 bash /tmp/find_spark.sh
#
# NOTE: the PXI has NO ssh-keyscan and NO usable nc. An earlier version of this
# script used ssh-keyscan and silently reported "port 22 closed" for hosts that
# were in fact running sshd. Port checks here use bash /dev/tcp instead.
#
# This script only NARROWS the candidates. It cannot prove identity, because
# proving identity means comparing the host key against known_hosts, which lives
# on the workstation. Do that final step from Windows:
#
#     ssh -o HostKeyAlias=spark-ac69.ni.corp.natinst.com \
#         -o StrictHostKeyChecking=yes nitest@<candidate>
#
# HostKeyAlias forces ssh to check the presented key against the stored entry
# for spark-ac69. It connects only on a real match, and refuses loudly otherwise,
# so a wrong box can never be silently accepted.
#
# Faster alternative that needs no remote host at all: sweep reverse DNS from
# the workstation, which is passive and names the box directly.
#
#     1..254 | ForEach-Object {
#         $r = Resolve-DnsName "10.198.65.$_" -Type PTR -QuickTimeout -EA 0
#         $r | Where-Object NameHost -match 'spark' |
#              ForEach-Object { "10.198.65.$_ -> $($_.NameHost)" } }
#
# Heads up: 10.198.65.105 is spark-b750, a DIFFERENT DGX Spark in the same lab.
# It shares the NVIDIA OUI and answers SSH, so it looks like a match until you
# check the key. Ours is spark-ac69.
set -u

SUBNET="${SUBNET:-10.198.65}"
# ed25519 host key of spark-ac69, from the known_hosts entry for the hostname.
SPARK_FP="${SPARK_FP:-SHA256:N5AfLpha8UApRqe3vVnu5AzM0jEna+M8A/2PmORpcD4}"
# NVIDIA OUI. The Spark's 50G ports are 4c:bb:47:2e:ac:6a / :6e; the management
# NIC is a different MAC, so match the vendor prefix rather than the full MAC.
OUI="${OUI:-4c:bb:47}"

echo "sweeping ${SUBNET}.0/24 to populate ARP ..."
for i in $(seq 1 254); do (ping -c1 -W1 "${SUBNET}.$i" >/dev/null 2>&1 &); done
sleep 10

echo
echo "=== hosts with OUI $OUI ==="
CANDS=$(ip neigh | grep -i "$OUI" | awk '{print $1}' | sort -u)
if [ -z "$CANDS" ]; then
    echo "  none found. The Spark is not on this subnet at all."
    exit 1
fi
ip neigh | grep -i "$OUI"

echo
echo "=== which candidates have sshd listening ==="
for ip in $CANDS; do
    if timeout 4 bash -c "exec 3<>/dev/tcp/$ip/22 && head -1 <&3" 2>/dev/null; then
        echo "    ^ $ip has sshd"
    else
        echo "  $ip  port 22 closed or filtered"
    fi
done

echo
echo "Candidates above are NOT confirmed to be the Spark. Verify each from the"
echo "workstation, which is where known_hosts lives:"
echo
for ip in $CANDS; do
    echo "    ssh -o HostKeyAlias=spark-ac69.ni.corp.natinst.com -o StrictHostKeyChecking=yes nitest@$ip"
done
echo
echo "A candidate that connects is the Spark. One that reports REMOTE HOST"
echo "IDENTIFICATION HAS CHANGED is a different machine, so leave it alone."
echo "If the real Spark is found at a new address, update HostName in"
echo "~/.ssh/config and the address recorded in LONGTERM_CONTEXT.md."
