#!/usr/bin/env bash
# How is the external-buffer (user-buffer) path actually meant to be driven?
#
# The header gives signatures but not the protocol. Before writing Gate 5 we need
# to know, for a RECEIVE session: after ConfigureExternalBuffer, do you post
# receives with QueueExternalBufferRegion, collect them with
# AcquireReceivedRegion, and re-arm with ReleaseUserBufferRegionToIdle? And does
# the region handed back point INTO our buffer?
#
# Read-only. Answers come from the vendor's own tests and implementation.

set -u
R=/home/admin/easyrdma
cd "$R" || { echo "no $R"; exit 1; }

echo "=== every call site of the external-buffer API, across the whole tree ==="
grep -rn --include=*.cpp --include=*.h --include=*.cc --include=*.hpp \
  -E 'ConfigureExternalBuffer|QueueExternalBufferRegion|ReleaseUserBufferRegionToIdle|Property_UserBuffers|DeferWhileUserBuffersOutstanding' . \
  | grep -v '/build/' | sed 's/^/  /'

echo
echo "=== doc comments around the declarations ==="
sed -n '1,60p' core/api/easyrdma.h | grep -n 'External' || true
grep -rn -B12 'easyrdma_ConfigureExternalBuffer' core/api/*.cpp 2>/dev/null | head -60

echo
echo "=== tests that exercise user buffers (names only) ==="
grep -rln -E 'ExternalBuffer|UserBuffer' --include=*.cpp --include=*.h . | grep -v '/build/' | sed 's/^/  /'

echo
echo "=== does the implementation register the caller pointer with ibv_reg_mr? ==="
grep -rn -E 'ibv_reg_mr|IBV_ACCESS' --include=*.cpp --include=*.h core/ | grep -v '/build/' | head -20

echo
echo "=== RdmaBufferQueue: how a user-buffer region is tracked ==="
ls -la core/common/ 2>/dev/null | sed 's/^/  /'
grep -n -E 'UserBuffer|External|Idle' core/common/RdmaBufferQueue.h 2>/dev/null | head -40
