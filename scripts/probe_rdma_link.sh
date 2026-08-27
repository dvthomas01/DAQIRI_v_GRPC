#!/usr/bin/env bash
set -u
D=/home/nitest/daqiri
echo "======== 1. libdaqiri location + is RDMA engine inside it? ========"
find "$D/build" -name 'libdaqiri*.so' -o -name 'libdaqiri*.a' 2>/dev/null | head
echo "--- engine libs ---"
find "$D/build" -path '*engines*' -name '*.so' -o -path '*engines*' -name '*.a' 2>/dev/null | head -20
echo
echo "======== 2. what daqiri_bench_rdma links (ldd) ========"
ldd "$D/build/examples/daqiri_bench_rdma" 2>/dev/null | grep -iE "ibverbs|rdmacm|daqiri|mlx|yaml" | head
echo
echo "======== 3. does libdaqiri pull ibverbs/rdmacm? ========"
ldd "$D/build/src/libdaqiri.so" 2>/dev/null | grep -iE "ibverbs|rdmacm|mlx" | head
echo
echo "======== 4. how examples/CMakeLists links daqiri_bench_rdma ========"
grep -nE "daqiri_bench_rdma|target_link|ibverbs|rdmacm|verbs|rdma" "$D/examples/CMakeLists.txt" 2>/dev/null | head -20
echo "DONE"
