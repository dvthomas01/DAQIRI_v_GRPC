#!/usr/bin/env bash
set -u
CC=/home/nitest/daqiri/src/engines/socket/daqiri_socket_engine.cpp

echo "===== socket options / recv / send flags ====="
grep -nE 'setsockopt|SO_RCVBUF|SO_SNDBUF|TCP_NODELAY|SO_REUSE|MSG_WAITALL|MSG_MORE|::recv|::send|recv\(|send\(|read\(|write\(' "$CC"

echo; echo "===== function line numbers ====="
grep -nE '::tcp_rx_loop|::send_tcp_burst|::send_tcp|::tcp_accept_loop|::setup_tcp_endpoint|::create_tcp_client' "$CC"

echo; echo "===== framing / length / reassembly references ====="
grep -nE 'payload_len|frame|header|hdr|tot_len|total_len|remaining|to_read|bytes_left|read_full|recv_all|MSG_WAITALL|reassembl|nbytes|n_read|recvd|received' "$CC" | head -80

echo; echo "===== tcp_rx_loop body (sed range) ====="
S=$(grep -nE '::tcp_rx_loop' "$CC" | head -1 | cut -d: -f1)
if [ -n "$S" ]; then sed -n "${S},$((S+90))p" "$CC"; fi

echo; echo "===== send_tcp_burst body (sed range) ====="
S2=$(grep -nE '::send_tcp_burst' "$CC" | head -1 | cut -d: -f1)
if [ -n "$S2" ]; then sed -n "${S2},$((S2+70))p" "$CC"; fi

echo DONE
