#!/usr/bin/env bash
# Phase 3 step 4: apply the external-buffer server path and build it.
# Run on the Spark. Idempotent; re-running just rebuilds.
set -u
export PATH="$HOME/.cargo/bin:/usr/local/cuda-13/bin:/usr/bin:/bin"

GD="$HOME/grpc-direct"
cd "$GD" || { echo "NO_GRPC_DIRECT"; exit 1; }

echo "== branch =="
git rev-parse --abbrev-ref HEAD
git rev-parse --short HEAD

# Snapshot before patching. The .bak files are gitignored.
n=8; while [ -e "src/lib.rs.bak$n" ]; do n=$((n+1)); done
cp src/lib.rs "src/lib.rs.bak$n"
echo "backup: src/lib.rs.bak$n"

echo "== patch =="
python3 /tmp/bind_extbuf_server.py "$GD/src/lib.rs" || { echo "PATCH_FAILED"; exit 1; }

echo "== build =="
export EASYRDMA_LIB_DIR="$HOME/easyrdma/core/build"
export EASYRDMA_INC_DIR="$HOME/easyrdma/core/api"
cargo build --release --features rdma 2>&1 | tail -60
echo "BUILD_EXIT=${PIPESTATUS[0]}"

echo "== exported symbols =="
nm -D --defined-only target/release/libgrpc_direct.so 2>/dev/null \
  | grep -E 'grpc_direct_server_(create_ext|receive_ext|slot_requeue)' || echo "NONE_FOUND"

echo "== stock path untouched =="
git diff --stat src/lib.rs
grep -n "fn rdma_server_create(" src/lib.rs
