#!/usr/bin/env bash
# Gate 5 run 1: ConfigureExternalBuffer accepted our cudaHostAlloc pointer (rc=0),
# but AcquireReceivedRegion then failed with InvalidOperation (-734004) at
# RdmaBufferQueue.cpp:105. So the completion is collected some other way.
#
# Questions:
#   1. What is RdmaBufferQueue.cpp:105 and why does it reject this?
#   2. How does the vendor's own test collect an external-buffer completion?
#   3. What is the correct teardown when a user buffer is outstanding? (Gate 5
#      also aborted with "double free or corruption" at exit.)

set -u
R=/home/admin/easyrdma
cd "$R" || { echo "no $R"; exit 1; }

echo "############ 1. RdmaBufferQueue.cpp around line 105 ############"
sed -n '60,140p' core/common/RdmaBufferQueue.cpp

echo
echo "############ 2. the BufferCompletion helper the tests use ############"
grep -rn -A40 'class BufferCompletion' tests/ | head -60

echo
echo "############ 3. QueueExternalBufferWithCallback in the test session wrapper ############"
grep -n -B5 -A25 'QueueExternalBufferWithCallback' tests/session/Session.h

echo
echo "############ 4. can AcquireReceivedRegion ever be used with external buffers? ############"
grep -n -B10 -A25 'WaitForCompletedBuffer' core/common/RdmaBufferQueue.cpp | head -70

echo
echo "############ 5. teardown with user buffers outstanding ############"
grep -n -B8 -A20 'DeferWhileUserBuffersOutstanding' core/api/rdma_api_common.h
grep -n -B5 -A20 'HasUserBuffersOutstanding' core/common/RdmaBufferQueue.cpp
