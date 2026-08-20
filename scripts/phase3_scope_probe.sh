#!/usr/bin/env bash
# Phase 3 scoping: read the grpc-direct Rust seam and easyrdma's API from the
# PXI copy, because the Spark (which holds the build tree) is off the network.
#
# Read-only. Prints; changes nothing.
set -u
GD=/home/admin/grpc-direct
ER=/home/admin/easyrdma

echo "############ 1. is the PXI copy a git clone (can we branch/fork from it)?"
ls -d "$GD/.git" 2>/dev/null && (cd "$GD" && git log --oneline -3 && git remote -v) || echo "  NO .git in $GD - it is a copy, not a clone"
echo
ls -d "$ER/.git" 2>/dev/null && (cd "$ER" && git log --oneline -3 && git remote -v) || echo "  NO .git in $ER"

echo
echo "############ 2. grpc-direct Cargo.toml (features, deps)"
cat "$GD/Cargo.toml"

echo
echo "############ 3. src/ layout with sizes"
ls -la "$GD/src"

echo
echo "############ 4. every mention of rdma in the Rust sources"
grep -rn --include=*.rs -i "rdma" "$GD/src" | head -60

echo
echo "############ 5. the transport enum and its dispatch in Rust"
grep -rn --include=*.rs -i "enum Transport\|Transport::\|SharedMemory\|not yet implemented\|unimplemented\|return null\|null_mut" "$GD/src" | head -60

echo
echo "############ 6. docs mentioning rdma or transport"
grep -rn -il "rdma" "$GD/docs" "$GD/README.md" "$GD/ARCHITECTURE.md" "$GD/AGENTS.md" 2>/dev/null

echo
echo "############ 7. easyrdma layout"
find "$ER/core" -maxdepth 3 -type d | head -40
echo "--- public headers / api ---"
find "$ER" -name "*.h" -o -name "*.hpp" | head -40
