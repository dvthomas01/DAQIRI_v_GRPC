#!/usr/bin/env bash
# Two questions Gate 5 depends on, answered from the vendor's own source:
#
#   1. Under what condition does ConfigureExternalBuffer on a RECEIVER return
#      easyrdma_Error_OperationNotSupported? (tests.cpp:2108 expects exactly that)
#   2. What is the correct call sequence for a receive session using external
#      buffers, and does the region handed back point INTO the caller's buffer?
#
# Read-only.

set -u
R=/home/admin/easyrdma
cd "$R" || { echo "no $R"; exit 1; }

echo "############ 1. the OperationNotSupported test ############"
sed -n '2085,2115p' tests/tests.cpp

echo
echo "############ 2. ConfigureExternalBuffer implementation ############"
sed -n '145,215p' core/common/RdmaConnectedSessionBase.cpp

echo
echo "############ 3. QueueExternalBufferRegion implementation ############"
sed -n '275,315p' core/common/RdmaConnectedSessionBase.cpp

echo
echo "############ 4. a receiver external-buffer test, start to finish ############"
sed -n '740,800p' tests/tests.cpp

echo
echo "############ 5. the test helper that wraps release-to-idle ############"
sed -n '195,265p' tests/session/Session.h

echo
echo "############ 6. RdmaBufferQueue.h in full (ownership model) ############"
cat core/common/RdmaBufferQueue.h
