#!/usr/bin/env bash
# Apply the external-buffer FFI bindings and prove they compile.
# Backs up lib.rs first, following the existing .bak convention on this box.
set -u
export PATH="$HOME/.cargo/bin:/usr/local/cuda-13/bin:/usr/bin:/bin"
GD="$HOME/grpc-direct"
cd "$GD" || exit 1

echo "### before ###"
md5sum src/lib.rs
wc -l src/lib.rs

# Keep the next number in the existing .bak chain rather than clobbering one.
n=5
while [ -e "src/lib.rs.bak$n" ]; do n=$((n+1)); done
cp src/lib.rs "src/lib.rs.bak$n"
echo "backup: src/lib.rs.bak$n"

python3 /tmp/bind_extbuf_ffi.py "$GD/src/lib.rs"
echo "PATCH_EXIT=$?"

echo
echo "### after ###"
md5sum src/lib.rs
wc -l src/lib.rs

echo
echo "### the new bindings ###"
grep -n 'ConfigureExternalBuffer\|QueueExternalBufferRegion\|BufferCompletionCallback\|PROPERTY_USER_BUFFERS\|CLOSE_DEFER' src/lib.rs

echo
echo "### cargo build --features rdma ###"
export EASYRDMA_LIB_DIR="$HOME/easyrdma/core/build"
export EASYRDMA_INC_DIR="$HOME/easyrdma/core/api"
ls -l "$EASYRDMA_LIB_DIR/libeasyrdma.so" || echo "MISSING libeasyrdma.so"
cargo build --release --features rdma 2>&1 | tail -40
echo "BUILD_EXIT=${PIPESTATUS[0]}"
