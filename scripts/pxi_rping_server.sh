#!/usr/bin/env bash
# Launch an rping RDMA server on the PXI RoCE IP, fully detached.
pkill -f 'rping -s' 2>/dev/null
rm -f /tmp/rping_srv.log
setsid bash -c 'timeout 30 rping -s -a 192.168.20.2 -v -C 10' </dev/null >/tmp/rping_srv.log 2>&1 &
sleep 1
echo "rping server launched on 192.168.20.2 (log /tmp/rping_srv.log)"
echo DONE_SRV_LAUNCH
