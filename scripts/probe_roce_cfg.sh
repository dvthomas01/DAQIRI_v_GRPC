#!/usr/bin/env bash
set -u
D=/home/nitest/daqiri
echo "===== A. daqiri_bench_rdma_tx_rx_spark.yaml (single-host, non-netns?) ====="
cat "$D/examples/daqiri_bench_rdma_tx_rx_spark.yaml"
echo
echo "===== B. daqiri_bench_rdma_tx_rx_spark_xhost.yaml ====="
cat "$D/examples/daqiri_bench_rdma_tx_rx_spark_xhost.yaml"
echo
echo "===== C. how engine resolves roce://X to a device (GID / device name) ====="
grep -rnE "roce://|resolve|gid|GID|ibv_get_device|device_name|dev_name|rdma_resolve|1\.1\.1\.1|roce_config|transport_mode|init.*rdma|rdma.*init|RDMAEngine|rdma_engine" \
    "$D/src/engines/" 2>/dev/null | grep -iE "roce|gid|resolve|device|rdma_engine|transport_mode" | head -50
echo
echo "===== D. RDMA engine init / how socket engine gets the rdma engine handle ====="
grep -rnE "initialized RDMA engine|rdma_engine|RdmaEngine|set_rdma|attach_rdma|rdma_init|init_rdma" \
    "$D/src/" 2>/dev/null | head -30
echo "DONE"
