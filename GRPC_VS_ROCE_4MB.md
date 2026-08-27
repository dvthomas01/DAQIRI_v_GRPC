# gRPC-Direct vs DAQiri RoCE — GPU FFT pipeline, sizes to 4 MB

Matched sweep: 9 buffer sizes (16 KB → 4 MB), copy + zero-copy, **200 buffers / 50
warmup / 400 µs pacing**, DGX Spark (GB10, unified NVLink-C2C). Both transports paced
identically so latency is clock-fair. Zero-copy = true in-place (host ptr == device
ptr on GB10) → H→D transfer = 0 µs on both.

All 18 gRPC-Direct runs **PASSED to 4 MB** (shmem transport). This was NOT previously
run past 128 KB; the old DAQiri *socket* pipeline fell off at 128 KB, but both
DAQiri **RoCE** and gRPC-Direct **shmem** now deliver the full 4 MB payload.

## Zero-copy — E2E latency p50 (µs), transfer = 0 both

| size | KB | RoCE p50 | gRPC p50 | RoCE p99 | gRPC p99 | winner |
|------|----|---------:|---------:|---------:|---------:|:------:|
| 4096 | 16 | 11.5 | 16.9 | 14.3 | 22.2 | RoCE |
| 8192 | 32 | 12.1 | 17.8 | 15.3 | 23.7 | RoCE |
| 16384 | 64 | 15.4 | 21.3 | 18.2 | 65.0 | RoCE |
| 32768 | 128 | 20.4 | 26.0 | 23.5 | 72.3 | RoCE |
| 65536 | 256 | 20.9 | 26.6 | 23.7 | 87.6 | RoCE |
| 131072 | 512 | 25.9 | 34.4 | 28.5 | 66.1 | RoCE |
| 262144 | 1024 | 28.2 | 47.4 | 30.7 | 84.6 | RoCE |
| 524288 | 2048 | 38.6 | 69.7 | 42.8 | 108.4 | RoCE |
| 1048576 | 4096 | **63.7** | **126.3** | **75.5** | **134.4** | **RoCE** |

RoCE wins zero-copy latency at every size. Gap widens with payload: ~1.5× at 16 KB
→ ~2.0× at 4 MB (p50). RoCE p99 tail is far tighter (75 µs vs 134 µs at 4 MB; and
much lower jitter at mid sizes where gRPC p99 spikes to 65–88 µs).

## Copy — E2E latency p50 / p99 (µs)

| size | KB | RoCE p50 | gRPC p50 | RoCE p99 | gRPC p99 |
|------|----|---------:|---------:|---------:|---------:|
| 4096 | 16 | 132.3 | 154.4 | 280.8 | 198.8 |
| 65536 | 256 | 125.0 | 159.6 | 297.5 | 246.8 |
| 262144 | 1024 | 172.4 | 195.5 | 383.5 | 334.1 |
| 524288 | 2048 | 194.0 | 244.0 | 404.6 | 301.9 |
| 1048576 | 4096 | **167.1** | **334.1** | **503.7** | **422.9** |

Copy mode is noisier. RoCE has the lower **median** at every size, but gRPC-Direct
has the lower **p99 tail** (its explicit H→D copy is more deterministic than RoCE's
copy-mode staging). At 4 MB copy: RoCE p50 2× lower, gRPC p99 ~16 % lower.

## Zero-copy vs copy (the real story)

At 4 MB, zero-copy vs its own copy path:
- RoCE: 63.7 µs vs 167.1 µs → **2.6× lower** median, transfer 0 vs 115 µs.
- gRPC: 126.3 µs vs 334.1 µs → **2.6× lower** median, transfer 0 vs 143 µs.

Both transports get the same ~2.6× win from in-place zero-copy on GB10.

## Delivery

- RoCE (RDMA RC): **200/200 measured, 0 dropped at every size** including 4 MB.
- gRPC shmem: session closes early at small sizes (172–175/200 measured for
  ≤128 KB), reaching full 200/200 only at ≥1 MB. Percentiles still stable.

## Bottom line

DAQiri RoCE is the lower-latency, tighter-tail, full-delivery transport at all
sizes to 4 MB. gRPC-Direct shmem now scales cleanly to 4 MB (it didn't before) and
matches the 2.6× zero-copy speedup, but sits ~1.5–2× behind RoCE on median latency
and drops buffers at small sizes. gRPC's one edge: a slightly lower copy-mode p99
tail.
