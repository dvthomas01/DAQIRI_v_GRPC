#!/usr/bin/env bash
set -u
D=/home/nitest/daqiri
echo "======== 1. rdma_bench.cpp: how --mode / single-process both-roles works ========"
grep -nE "mode|server|client|--seconds|both|run\(|std::thread|launch|role|argv|argc" \
  "$D/examples/rdma_bench.cpp" 2>/dev/null | head -50
echo
echo "======== 2. RDMA-CM: does it reject/allow local dst (loopback) addr? ========"
sed -n '1000,1075p' "$D/src/engines/rdma/daqiri_rdma_engine.cpp"
echo "DONE"
