#!/usr/bin/env bash
# Exact line numbers and guards for every behavioural change in the fork's
# client_interceptor.cc, so the answer is call sites rather than an impression.
set -u
cd "$HOME/grpc-direct" || exit 1

echo "###### the 5 changed regions, with current line numbers ######"
grep -n 'firstRecv_\|serverStreamEnded_\|FailHijackedRecvMessage\|isFirstMessage_' cpp/client_interceptor.cc

echo
echo "###### PRE_RECV_MESSAGE block in full (the only behavioural hunk) ######"
awk '/PRE_RECV_MESSAGE/{f=1} f{print NR": "$0} /PRE_RECV_STATUS/{if(f)exit}' cpp/client_interceptor.cc | head -90

echo
echo "###### CMake: what goes into grpc_direct_cpp ######"
sed -n '295,320p' CMakeLists.txt
