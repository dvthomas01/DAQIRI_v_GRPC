#!/usr/bin/env bash
# List available RDMA test tools + device state.
for t in ib_send_bw ib_write_bw ib_read_bw ibv_rc_pingpong rping ucmatose rdma_server rdma_client rdma-ping; do
  p=$(command -v "$t" 2>/dev/null || echo MISSING)
  printf '%-18s %s\n' "$t" "$p"
done
echo "--- device state (link_layer must be Ethernet for RoCE) ---"
ibv_devinfo 2>/dev/null | grep -E 'hca_id|phys_state|state:|link_layer' | head -30
echo DONE_TOOLS
