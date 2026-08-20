#!/usr/bin/env bash
# Does our benchmark's interceptor come from the file that was modified?
#
# bench_grpc_client.cc includes <sharedmem_client_interceptor.h> and constructs
# DirectTransportInterceptorFactory. The modified file is cpp/client_interceptor.cc.
# Those may or may not be the same interceptor. Establish it by symbol, not by name.
set -u
cd "$HOME/grpc-direct" || exit 1

echo "###### which cpp/ files exist ######"
ls -l cpp/ include/ 2>/dev/null

echo
echo "###### where is DirectTransportInterceptorFactory DEFINED? ######"
grep -rn 'DirectTransportInterceptorFactory' cpp/ include/ --include=*.cc --include=*.h | grep -v '\.bak'

echo
echo "###### what does sharedmem_client_interceptor.h contain? ######"
sed -n '1,60p' include/sharedmem_client_interceptor.h

echo
echo "###### top of cpp/client_interceptor.cc: what class does it define? ######"
sed -n '1,40p' cpp/client_interceptor.cc

echo
echo "###### which .cc files does the cpp library build from? ######"
grep -rn 'client_interceptor\|add_library\|GLOB' CMakeLists.txt cpp/CMakeLists.txt 2>/dev/null | head -40

echo
echo "###### ClientRpcInfo::Type checks in the interceptor ######"
grep -n 'ClientRpcInfo::Type\|callType\|CLIENT_STREAMING\|SERVER_STREAMING\|BIDI\|UNARY' cpp/client_interceptor.cc
