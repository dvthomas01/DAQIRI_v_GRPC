#!/usr/bin/env bash
# Probe DAQiri's socket transport for buffer/reassembly controls.
set -u

echo "===== 1. DAQiri headers on system ====="
mapfile -t HDRS < <(find / -name 'daqiri*.h' -o -name 'daqiri.h' 2>/dev/null | sort -u)
printf '%s\n' "${HDRS[@]}"

echo
echo "===== 2. Socket / buffer / reassembly API symbols in headers ====="
for h in "${HDRS[@]}"; do
  echo "--- $h"
  grep -nEi 'setsockopt|getsockopt|rcvbuf|sndbuf|so_rcv|so_snd|recv_buf|send_buf|socket_opt|sockopt|reassemb|fragment|segment|max_payload|packet_len|payload_size|window|mtu|nodelay|tcp_' "$h" 2>/dev/null
done

echo
echo "===== 3. Any DAQiri shared libs (for symbol dump) ====="
mapfile -t LIBS < <(find / -name 'libdaqiri*.so*' 2>/dev/null | sort -u)
printf '%s\n' "${LIBS[@]}"
for l in "${LIBS[@]}"; do
  echo "--- exported socket/buffer symbols in $l"
  nm -D --defined-only "$l" 2>/dev/null | grep -Ei 'sockopt|rcvbuf|sndbuf|buffer|payload|reassemb|fragment|socket' | head -40
done

echo
echo "===== 4. DAQiri config schema keys (socket_config) ====="
mapfile -t SCHEMAS < <(find / -path '*daqiri*' \( -name '*.yaml' -o -name '*.json' -o -name '*schema*' \) 2>/dev/null | grep -Ei 'schema|example|template|default' | head -20)
printf '%s\n' "${SCHEMAS[@]}"
# Also grep any daqiri source/docs for socket buffer config keys
grep -rnEi 'so_rcvbuf|so_sndbuf|rcv_buffer|snd_buffer|recv_buffer_size|send_buffer_size|socket_buffer|max_payload_size|read_chunk|recv_chunk' \
  /usr/include /usr/local 2>/dev/null | grep -i daqiri | head -40

echo
echo "===== 5. Kernel socket buffer ceilings (read-only) ====="
sysctl net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default 2>/dev/null
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem 2>/dev/null
echo "loopback MTU:"; ip link show lo 2>/dev/null | grep -o 'mtu [0-9]*'

echo
echo "===== 6. Can we raise socket buffers without sudo? (probe) ====="
python3 - <<'PY' 2>/dev/null || echo "python3 socket probe unavailable"
import socket
for want in (4*1024*1024, 8*1024*1024):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, want)
        got = s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        print(f"SO_RCVBUF requested={want} -> got={got} (kernel doubles for bookkeeping)")
    except Exception as e:
        print("SO_RCVBUF set failed:", e)
    s.close()
PY
echo DONE
