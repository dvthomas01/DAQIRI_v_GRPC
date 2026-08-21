# Short-Term Context — Active Sprint
**Phase:** RDMA transport for gRPC-Direct — measuring the transport itself
**Branch:** `grpc-direct-optimization` @ `ceb03b3`, pushed (cut from `main` @ 57ba6d3; `main` untouched)
**Updated:** 2026-08-21 (late)

> **This file is committed now.** It was gitignored while tracked documents pointed at it.

---

## THE HEADLINE, 2026-08-21 LATE: the pipeline is at the wire, and one mechanism is retracted

Full writeup in `handoff.md` §7j. Read it with §7i, which it corrects.

**1. The 3.18x was real. The reason given for it was not.** §7i said the receiver's spectral
check cost 3.18x because it held the slot between the transform's gate and `slot_requeue`, so
the NIC could not refill it. `detect_peaks` reads `d_out`, device memory holding the transform's
output, and never touches the slot, so it was moved below the re-queue. `hold_us` fell from
2488 µs to **1.5 µs** and the rate **did not move**: 1611/1511/1576 MiB/s against 1561/1566/1458
before. The credit window was never the mechanism.

The mechanism is that the receiver is one thread. `detect_peaks` costs about 2400 µs of it per
message at 4 MiB and `receive_ext` cannot be called again until it returns, so the arrival
interval is the consumer's loop time wherever in the loop the work sits. That is also why the
slot sweep in §7i was flat: buffering absorbs bursts, and this producer is continuous and faster
than us. **The practical consequence: this is not fixable by reordering.** Verifying every
message at 4 MiB needs sampling or a second thread, or throughput and correctness stay separate
runs.

**2. The sender's own copy was the whole remaining gap, and removing it reaches line rate.**
`--gen inplace` on the client builds the sixteen frames complete at startup and writes only a
16-byte header per message.

| arm | gen p50 (µs) | send p50 (µs) | gap p50 (µs) | MiB/s |
|---|---|---|---|---|
| `stream-nv` (`--gen copy`) | 467.12, 468.70, 467.40 | 335.70, 335.25, 336.79 | 783.51, 804.39, 801.67 | 5100, 4973, 4989 |
| `stream-inplace` | 0.16, 0.16, 0.13 | 688.20, 688.65, 687.99 | 662.98, 686.23, 680.29 | 6031, 5829, 5878 |

Three of three, no overlap. `gap_p50` lands on the **685 µs** wire time and 5878 MiB/s median
against Gate 3's measured **5843 MiB/s**. **The transport is not the bottleneck.** The "receive
path sustains 85 percent of link" line is retired: the 85 percent was the harness measuring its
own memcpy. A digitizer DMAs into the buffer it hands to the transport, so the inplace arm is
also the more faithful one.

**3. The binary now withholds the numbers it cannot support.** With `--poison on` or
`--verify every` the server prints no inter-arrival, no sustained rate and no consumer duty,
just the reason and the two contrasting figures. Not a warning. §7i happened because a rate sat
in a log for a month with a comment somewhere else saying not to trust it. `phase4_cell.sh`
keeps `--verify every`, which is right for the latency columns it quotes, and its `mib_s` now
comes out `NA`. Verified against a live rep.

**Next:** DAQiri cross-machine. Both DAQiri benchmarks are single-process loopback with both
endpoints on the same address while the extbuf arm is genuinely PXI to Spark, so the standing
comparison is loopback against wire. Needs `bench_daqiri_roce_pipeline.cc` split into real
client and server roles.

---

## THE PREVIOUS HEADLINE, 2026-08-21: we were never measuring the transport, and the stall was ours

Full writeup in `handoff.md` §7i. Three findings, all of which change conclusions this project
had already written down.

**1. There is a transport number now, and it is about 1364 µs.** Every latency figure before
today started its clock *after* the data had landed. Post-to-FFT-complete from the PXI at
4 MiB, measured by round-trip echo, is 1269.7 / 1415.0 / 1364.2 µs across three reps with the
calibration arm subtracted paired. Median about **1364 µs**, three of three.

It had to be a round trip. The PXI's realtime clock is **23.13 seconds ahead** of the Spark's
and neither box runs NTP or chrony, so differencing wall clocks across the two machines
produces nothing. The sender timestamps before it posts, the receiver acks 16 bytes immediately
after the transform's gate, the sender timestamps the ack. One clock throughout.

**Two caveats that must travel with the number.** Waiting for the ack serialises the sender,
because the RDMA pending response is a thread-local slot the next send overwrites, so this is
**unloaded** latency and not the per-message cost under load. And rep 1's calibration is an
outlier, 109 µs against 23 and 27, so that row's difference is the weakest of the three.

**2. The sender's 2205 µs stall was the receiver's own spectral check.** `detect_peaks` runs
between the transform's gate and `grpc_direct_server_slot_requeue`, so for two and a half
milliseconds a slot the NIC could be refilling is sitting in a peak search. The sender blocks in
`AcquireSendRegion` for exactly that long and reports it as send time. Turning it off:

| arm | hold p50 (µs) | send p50 (µs) | gap p50 (µs) | MiB/s |
|---|---|---|---|---|
| `--verify every` | 2488, 2480, 2666 | 2091, 2070, 2251 | 2562, 2553, 2743 | 1561, 1566, 1458 |
| `--verify off` | 12, 12, 14 | 341, 332, 345 | 812, 776, 821 | 4925, 5149, 4875 |

Three of three, no overlap, **3.18x**. 4983 MiB/s against the 5843 Gate 3 measured, so **85
percent of the link where it had been 27**. `rdma/extbuf_fft_server.cu` already carried the
comment that Phase 4 needs `--verify off`; `scripts/phase4_cell.sh:193` passed `--verify every`.
The two files disagreed in the repository for a month.

**Consequence for what is already written down: Phase 4's cell ran with verification on, so its
throughput and blocked-send figures are contaminated and must not be quoted.** Its latency
columns are unaffected, because they stop at the gate, so the two-provenance result in §7h
stands.

**3. Slot depth is closed negative, and the sender's CPU is the new bound.** `stream-nv` at
2, 4, 8 and 16 slots lands between 4785 and 5149 MiB/s, one distribution. Depth was the most
attractive of the four candidates because it would have been a one-line fix with a large effect,
and it was wrong. What limits it now is `gen_p50` 468 µs plus `send_p50` 335 µs of
single-threaded host memcpy against an arrival interval of 800 µs: the PXI copies 4 MiB twice
per message, once building the frame and once inside `grpc_direct_client_send`.

So the receive path sustains 85 percent of line rate and the limit is a synthetic sender doing
work a real digitizer would not do. **That framing is currently an assertion, and measuring it
is the next experiment.**

---

## RESOLVED: the Spark is back (2026-08-20)

It was power-cycled and returned at the same address, 10.198.65.106. Both machines are
reachable and the RoCE fabric is up end to end. Phase 3 is unblocked. Two lessons from the
outage are kept below because both are durable.

**Before blaming either box, check the VPN (added 2026-08-21).** Both hosts timed out for an
hour and both were fine: the Spark reported `up 21:52` when it came back, so it had never gone
down. This workstation had dropped off the NI network onto home Wi-Fi. Every wired adapter sat
on a `169.254/16` APIPA address, the only route was a home gateway, and FortiClient was running
with its tunnel down. One line settles it, and it is cheaper than an ARP sweep:
`Get-NetIPAddress -AddressFamily IPv4 | ? { $_.IPAddress -notlike '127.*' }`. If nothing is on
`10.198.65.x`, the VPN is down and no amount of probing the lab will say so.

**Do not trust `ip neigh` without flushing first.** The first check from the PXI showed
`10.198.65.106 dev eno0 lladdr 4c:bb:47:2e:ac:69 DELAY`, i.e. the Spark's own management MAC,
which reads exactly like "the box is alive". It was a stale cache entry. After
`ip neigh flush dev eno0` and a fresh ping the same lookup returned `FAILED`. An ARP sweep of
the whole /24 (`scripts/find_spark_arp.sh`, run from the PXI) found three other NVIDIA-OUI
hosts and **not** `4c:bb:47:2e:ac:69`. Use the sweep, not a single-address lookup: only the
sweep distinguishes "off the network" from "at a new DHCP lease".

**The PXI's RoCE address dies on a Spark power cycle, not only on a PXI reboot.** This
corrects what the recovery steps used to say. When the Spark came back the PXI had `up 13
days` and had *still* lost `192.168.20.2/24`, reverting to a `169.254/16` link-local address.
The trigger is the carrier flap on the direct link, not a reboot, so it happens every time the
Spark is power-cycled. `mtu 9000` survived; only the address was replaced. Recovery is
`scripts/roce_restore_pxi.sh`, run as root on the PXI.

**The GID index moves with the address, so read it.** It is a position in a list, not an
identity. After recovery the PXI's RoCE v2 IPv4 GID was back at index 5, which is what
`rdma/rdma_fft_client.cc` defaults to, but only because the link-local address is *also* still
present and occupies indices 2 and 3 ahead of it. Remove the link-local and 192.168.20.2 slides
down to index 3. Never quote a GID index from memory; read it and check the address it carries.

## THE HEADLINE: the transport is built and verified end to end

**Phase 2 passes.** The PXI RDMA-writes over RoCE into a `cudaHostAlloc`'d pool on the Spark
and cuFFT transforms those bytes in place. 1800 messages verified across all nine sizes plus a
30,000-message soak, zero completion errors, zero timeouts, and `1 alloc, 1 reg_mr,
4 translate` at startup and unchanged at the end.

**The control that makes that mean anything ran first.** With cuFFT deliberately launched
before the completion is observed, 59 of 60 messages fail and report the 400 kHz poison tone.
One 16 KB message in twenty passed anyway, so the ordering test's sensitivity is itself
size-dependent and needs enough messages at the smallest payload.

**Phase 1 is negative and it corrected the headline.** No `cudaHostRegister` flag recovers any
part of the penalty: allocation arms close 94–101% of the gap at every size, registration arms
close about none. And the transform penalty **does not exist below about 1 MB**, so the
10.94 µs figure means 10.94 µs *at 4 MB* and nothing else. Pooling nine sizes into one sign
test had diluted a real 15 µs effect at 4 MB into p = 1.

## What Phase 3 has to solve, in one paragraph

The Rust `grpc-direct` library **already implements** `GRPC_DIRECT_TRANSPORT_RDMA` over NI
easyrdma; the "not yet implemented, returns NULL" comment in the header is stale. But it calls
`easyrdma_ConfigureBuffers`, which makes **easyrdma** allocate and register the landing buffer.
That is precisely the `cudaHostRegister`-shaped arrangement Phase 1 measured and Phase 2 was
built to escape. The fix is `easyrdma_ConfigureExternalBuffer`, which takes a caller-supplied
pointer, so we can hand it a `cudaHostAlloc`'d pool. Full breakdown, including the three
ownership questions, is in `rdma_transport_plan.md` §6.

---

## Superseded headline (2026-08-19), kept because the retraction is the point

**`cudaHostAlloc` beats `cudaHostRegister` by 10.94 µs of transform time at 4 MB, which is
larger than the entire remaining 8.10 µs gap to DAQiri.** DAQiri allocates with
`cudaMallocHost`; we receive an iceoryx2 `/dev/shm` buffer and register it after the fact.
Owning the allocation is the whole difference.

4 MB, 15 reps, 200 iters, arms rotated so no arm keeps a fixed slot (`data/pagesize_rot.csv`):

| arm | how built | write | transform | total |
|---|---|---|---|---|
| `hostalloc` | `cudaHostAlloc` | **56.75** | **53.22** | **109.83** |
| `heapreg` | `malloc` + `cudaHostRegister` | 118.66 | 63.07 | 181.87 |
| `shmreg` | `/dev/shm` + `cudaHostRegister` | 117.49 | 64.19 | 181.57 |
| `hugereg` | verified 2 MB THP + `cudaHostRegister` | 114.53 | 66.91 | 181.65 |

`shmreg` slower than `hostalloc` **15/15, p = 6.104e-05**. `heapreg` and `hugereg` are each
**0/15** faster than `hostalloc`. The three slow arms share nothing but `cudaHostRegister`:
they differ in page size, in `MAP_PRIVATE` vs `MAP_SHARED`, and in pre-faulting, and land
within 0.3 µs of each other. Both paths use `...Mapped` plus `cudaHostGetDevicePointer`, so
pointer acquisition is not the difference.

**RETRACTION.** The earlier memory-kind ladder declared this dead. It was read-only: it never
wrote to the buffer before transforming it. Real pipelines always write first. Dirty the
buffer and the arms separate immediately. The read-only caveat had been noted and not acted on.

That the **CPU write** is also ~2x slower on registered memory is the strongest clue to the
mechanism, since registration has no business changing CPU store speed unless it also changes
the page's cacheability or coherency attributes. On a C2C-coherent part that is plausible.

## Mechanisms eliminated (do not re-test without new reasoning)

| Mechanism | Evidence | Verdict |
|---|---|---|
| Registration granularity | `--zc-bigreg`, 9/15, p = 0.61 | null (rerun once under write discipline) |
| Page size | `hugereg` with verified `anonhuge=4096kB` matched `shmreg` to 0.3 µs | **innocent** |
| NUMA / page attributes | `numactl --hardware` = 1 node, 122571 MB | no GPU node exists |
| Wait method | `optblock` lost at all 6 sizes, e2e 1/18 p = 0.000145 | `--opt-stream` correct |
| Memory kind | **RETRACTED — it IS the mechanism** | see headline |

## Device-landing (i-RDMA into GPU memory) is closed for CPU producers

- A CPU store into a `cudaMalloc`'d pointer **FAULTS** on GB10, at every size. Only a DMA
  engine can write there.
- Copy-to-device is dead: 4 MB write 448.71 + fft 43.52 = 492.23 vs `shmreg` total 287.60.
- Managed memory with `cudaMemAdviseSetPreferredLocation(GPU)` + prefetch still transforms at
  70.43, i.e. host speed. The CPU write migrates pages straight back.
- **DAQiri also lands in HOST memory** (`cudaMallocHost`). It is not doing GPU-direct either.
  This is why the new assignment terminates in host memory on purpose.

## Where we are

The cross-machine RoCE test is **un-shelved**: it is now the main line of work (see Assignment).
The goal is unchanged — match or beat DAQiri, keep the gRPC API intact, every optimization
behind a mode flag so the baseline stays measurable.

- **Headline, from a 54-run interleaved sweep** (`data/headline_runs.csv`, commit `efe712d`):
  at 4 MB the optimized path is **1.80×** the baseline (127.02 → 70.41 µs) and sits **1.13×**
  off DAQiri (62.31 µs). We went from 1.76× slower to 1.13× slower. DAQiri is still ahead at
  every size.
- **The remaining gap is mostly inside cuFFT.** Decomposed within each (size, rep) cell:
  ~80 % of the 8.10 µs at 4 MB is transform time, and the cuFFT component grows with payload
  (0.77 µs at 16 KB to 6.40 µs at 4 MB). Transport contributes 0.3 to 1.7 µs. This **reverses**
  the earlier "the transform is not involved" claim.
- **The residual problem really is solved.** gRPC residual is now flat at 5.5–6.7 µs across a
  256× size range against DAQiri's 4.9–5.0. That was the E2 win and it held up under repetition.
- **Same transform on both sides, confirmed by code read.** Same plan, same strides, out-of-place
  in both, output to device memory in both, same warmup, plan built once. The only real
  difference is where the transform **reads from**.
- **Memory-source ladder is real** (4 MB, paired): device `cudaMalloc` 45.15 < DAQiri pinned MR
  57.36 < our registered iceoryx2 shmem 63.76 µs, 18/18 cells, p = 7.6e-06.
- **Registration granularity is exonerated.** `--zc-bigreg` (64 KB GPU-page rounding, i.e. what
  DAQiri does) re-measured properly at 3 reps × 5 sizes: 9/15, p = 0.61. A clean null.
- **The `n` shortfall is benign.** gRPC reports 171–200 received vs DAQiri's 250, but the
  shortfall *shrinks* with size and all 18 windows are contiguous with 0 holes. Windows are
  truncated at the **head**, during warmup, because warmup counts received messages rather than
  sequence numbers. No published percentile is affected. This is no longer a bug to fix.

## Scoreboard (4 MB, p50 µs, from the 2-rep interleaved sweep)

| | e2e | fft | residual |
|---|---|---|---|
| gRPC baseline (`--no-zc-align --no-opt-stream`) | 127.02 | 45.15 | 81.88 |
| **gRPC optimized (current defaults)** | **70.41** | 63.76 | 6.65 |
| DAQiri RoCE | 62.31 | 57.36 | 4.95 |

Note the baseline's *faster* FFT (45.15). It reads from `cudaMalloc`'d device memory because it
copies first; it just pays 81.88 µs of residual to get there. That contrast is the whole
placement story in one table.

## Mode flags

| Flag | Experiment | Verdict |
|---|---|---|
| `--stage-timing` | Phase 0 attribution | keep, diagnostic |
| `--zc-align` | E2: probe cuFFT instead of assuming 16 B | **ADOPTED, now default on** |
| `--opt-stream` | dedicated non-blocking stream + `cufftSetStream` | **ADOPTED, now default on** |
| `--opt-nolock` | drop the global mutex + hashmap | opt-in, unresolved |
| `--opt-affinity` | pin the handler thread | opt-in, unresolved |
| `--zc-h2d` | E1: realign via H2D from pinned host | rejected, no change + worse p99 |
| `--zc-kernel` | E3: SM copy → device-memory FFT | rejected, 110.8 vs 76.4 |
| `--zc-bigreg` | E4: register whole 64 KB GPU pages | **rejected again**, 9/15 p = 0.61 |
| `--verify` | top-3 spectral peaks vs expected tones | keep, correctness gate |

`base` in the sweep means `--no-zc-align --no-opt-stream`, so `base` vs `opt` differs in **two**
ways and is confounded for placement questions. Only `opt` vs `daq` is clean.

## Immediate Next Steps — Phase 3, integration into the Rust transport

Scoping is written up in `rdma_transport_plan.md` §6 and should be read before any code. The
short version:

1. **Fork `grpc-direct` properly — DONE, and it came back clean.** The PXI copy at
   `/home/admin/grpc-direct` has no `.git` and four `lib.rs.bak*` files, so provenance had to be
   established by content. Upstream is `https://github.com/ni/grpc-direct.git`. Against upstream
   HEAD `2d404a5` (2026-06-11) **125 of 127 tracked files are byte-identical**; the only real
   source change is `src/lib.rs`, +529/-31. The other "difference", `python/pyproject.toml` plus
   a pile of moved files, is a `pip install -e .` layout change and build residue. The four
   `.bak` files are strictly monotone snapshots of the same afternoon's work: no function
   defined in any snapshot is missing from the current file, so nothing was tried and quietly
   reverted. Details in `rdma_transport_plan.md` §6.5. Reproduce with
   `scripts/diff_grpc_direct_upstream.ps1` and `scripts/audit_libr_baks.sh`.
2. **Gate 5 — DONE 2026-08-20, PASS.** `easyrdma_ConfigureExternalBuffer` accepts a 64 MiB
   `cudaHostAlloc` pool, the bytes land at the offset we pick, the rest of the pool stays
   untouched, and a GPU kernel reads them in place. Control with stock `ConfigureBuffers` lands
   outside the pool and still transfers, so it is live. 17 checks, 0 failures, 3 reps.
   `scripts/gate5_extbuf.cu`, output `data/gate5_extbuf.txt` and `data/gate5_reps.txt`.
   Three protocol corrections came out of it, all now in `rdma_transport_plan.md` §6.4:
   completion is **callback-only**, there is **no release call**, and teardown needs
   `DeferWhileUserBuffersOutstanding` or the heap corrupts. Plus one Phase 4 constraint: **RX
   polling and external buffers are mutually exclusive** (-734026), so the `rdma` arm cannot
   poll and an `rdma-stock-nopoll` arm is needed to keep the comparison honest.
3. **Swap `ConfigureBuffers` for `ConfigureExternalBuffer`** so the landing buffer is ours and
   `cudaHostAlloc`'d, then prove by measurement that the allocator penalty is gone. Confirmed by
   the diff: **no external-buffer API is called anywhere**, in upstream, in the fork, or in any
   `.bak`. The seam is genuinely unbound, so it has to be added rather than switched on. Bind
   two functions, not three: `ConfigureExternalBuffer` and `QueueExternalBufferRegion`, plus the
   completion-callback struct. `ReleaseUserBufferRegionToIdle` is not on this path.
4. **Answer the three ownership questions** that Phase 2's lockstep design deferred rather than
   solved: who owns a slot between arrival and FFT completion, how the sender learns a slot was
   freed, and what happens when the sender outruns the receiver. **(b) is now answered** by
   Gate 5: re-queueing is the only re-arm and also the credit, and since the memory is ours
   throughout, the hazard is re-queue-before-completion rather than release-before-completion.
5. Only then Phase 4, the five-arm comparison.

### When comparing the fork against upstream, turn line-ending translation off

The first comparison reported 123 of 127 files modified. That was not a result, it was
`core.autocrlf` checking the clone out with CRLF on Windows against the PXI's LF. Clone with
`git -c core.autocrlf=false -c core.eol=lf clone ...` and the count drops to 2. A diff tool that
says almost everything changed is reporting on itself, not on the code.

### Historical: the assignment as originally written

**The design.** The PXIe-8881 does an RDMA write over RoCE into a buffer on the Spark. That
buffer was allocated with `cudaHostAlloc` + `cudaHostAllocMapped` and registered with the NIC
via `ibv_reg_mr`. The Spark polls the completion, then hands cuFFT the device pointer from
`cudaHostGetDevicePointer` and transforms in place. No copy anywhere: the NIC writes once, the
GPU reads what the NIC wrote. Still zero-copy, it just terminates in **host** memory rather
than device memory, because on this chip host memory is what the GPU reads from anyway.

Two things to say out loud when pitching it:

1. **This is DAQiri's architecture.** It already does RoCE into `cudaMallocHost` buffers. We
   are not inventing a faster path, we are giving gRPC-Direct the same one. The claim is
   "DAQiri performance without giving up the gRPC API", which was the original project goal.
2. **The justification is our own measurement**, the 10.94 µs at 4 MB above. Today iceoryx2
   allocates with `shm_open` and we register after the fact. Owning the allocation is the point.

### Four gates before any of it gets built — ALL FOUR PASSED, 2026-08-19

| Gate | What | Result |
|---|---|---|
| 1 | CUDA attribute probe, `scripts/gate1_caps.cu` | **PASS**. `CAN_USE_HOST_POINTER_FOR_REGISTERED_MEM=1`, and the allocation confirmed it: host ptr and device ptr are the same address `0x32ee00000`, 2 MB aligned. So `cudaHostGetDevicePointer` is optional here, not load-bearing. |
| 2 | RoCE up on both ends with a usable address | **PASS**. `enp117s0` came up on its own at 50 Gb/s. Needed a temporary address to be reachable. |
| 3 | `ib_write_lat` / `ib_write_bw` PXI → Spark | **PASS**. 1.81 µs typical small-message, 5843 MiB/s at 4 MB = 98% of line rate. |
| 4 | **Decisive.** `ibv_reg_mr` on a `cudaHostAlloc` buffer | **PASS**. lkey/rkey `0x00182ae7`, `mr->addr` and `mr->length` match the CUDA allocation exactly, GPU wrote and CPU read back coherently. |

**Gate 1 also killed the device-memory route with hardware evidence.** `GPU_DIRECT_RDMA_SUPPORTED
= 0` and `DMA_BUF_SUPPORTED = 0`, but `HOST_ALLOC_DMA_BUF_SUPPORTED = 1`. Third-party DMA into
device memory is unsupported on GB10; into page-locked host memory it is supported. handoff §7b
ranked GPUDirect RDMA first; that ranking is retired. Host landing is not second-best, it is the
only option the hardware offers. `nvidia-peermem` exists but will not load without root, and it
is moot anyway since it exists to expose device memory.

**Gate 4's control is worth as much as its result.** The same `ibv_reg_mr` on `cudaMalloc`'d
device memory was rejected with "Bad address". That turns "we chose host memory" from a
preference into a demonstrated constraint.

**Gate 3's conclusion changes the framing.** The fabric runs at 98% of line rate, so there is
nothing left to win in the transport. Everything still on the table is in what happens after the
bytes land, which is exactly what this design changes. The 695 µs it takes to move 4 MB is paid
identically by DAQiri and cancels out of the comparison; the 10.94 µs registration penalty at
that same 4 MB does not.

Evidence committed at `data/gate1_caps.txt`, `data/gate3_fabric.txt`, `data/gate4_regmr.txt`;
probes at `scripts/gate1_caps.cu` and `scripts/gate4_regmr.cu`. Commits `c91614c` and `c875e0c`.

All four passed, so the architecture is feasible and **Phase 1 is the flag experiment**. The
abort condition (Gate 4 fails, project stops) did not trigger.

### Machine state that does NOT survive a reboot

Two lines, both needed, both lost on reboot. Run as root on the PXI:

```sh
ip addr add 192.168.20.2/24 dev enp117s0
ip link set dev enp117s0 mtu 9000
```

The PXI gets no DHCP lease on `enp117s0` and comes up link-local only, which cannot reach the
Spark's `192.168.20.1`. It also comes up at MTU 1500, giving RoCE `active_mtu` 1024 against the
Spark's 4096; a queue pair silently negotiates the minimum and you lose about 5% of bandwidth
with no error anywhere. Measured: 730.29 → 694.76 µs and 5518 → 5843 MiB/s at 4 MB after
aligning, with the 2-byte case unchanged as a control.

GID indices for perftest `-x`: PXI RoCE v2/IPv4 is **5**, Spark is **3**. These shift when
addresses come and go, so read them from
`/sys/class/infiniband/<dev>/ports/1/gid_attrs/types/<i>` rather than assuming.

perftest is now built on the PXI at `/home/admin/perftest`, from source, nothing installed
system-wide. It needs libpci, which is absent and has no configure skip flag, so libpci was
built into `/home/admin/pciutils-inst` rather than stubbed out. Full recipe in handoff §7d.

### Cheaper experiments that should run alongside (they may make the RDMA work unnecessary) — ALL RESOLVED, ALL NEGATIVE

1. **`cudaHostRegisterDefault` / `cudaHostRegisterPortable` vs `Mapped`** on the same `/dev/shm`
   buffer. This is the difference between "needs an iceoryx2 change" and "one flag".
   **Answered: null.** `Default` 165.55, `Portable` 162.86 against `Mapped` 162.03 at 4 MB, all
   far from `hostalloc`'s 113.30. `WriteCombined` also null, and `ReadOnly` is refused by the
   driver. No flag fixes it.
2. **Re-run `--zc-bigreg`** under write-then-transform discipline. It was null, but that was
   before we knew to dirty the buffer first. **Answered: null again**, 166.43 at 4 MB.
3. Only then the Rust-side work of having the transport hand us driver-allocated memory.
   **This is now the live item and it is Phase 3.**

## Open Questions / Caveats

- [x] **Why does registered memory lose to `cudaHostAlloc` on GB10?** The *mechanism* is still
      unproven, but the search for a cheap fix is over: no flag recovers any of it, and
      `WriteCombined` demonstrably takes a different driver path (`/dev/nvidiactl`, vmflags
      `... de dd mm`) with identical timing. The penalty is also **size-dependent**, absent
      below about 1 MB, which is a real constraint on any explanation.
- [ ] **Does the penalty follow easyrdma's internally-allocated buffer?** Untested and it is
      the first thing Phase 3 must measure. If `ConfigureExternalBuffer` with a
      `cudaHostAlloc`'d pool does not beat `ConfigureBuffers`, the premise of the whole
      transport is wrong and we should find that out in a probe, not in Phase 4.
- [ ] **Never trust `ip neigh` without flushing it.** A stale entry reported the Spark alive,
      with the correct MAC, when nothing was at the address.
- [x] `cudaHostRegisterReadOnly` is rejected outright by the GB10 driver ("operation not
      supported"). `Default` and `Portable` have now been tried and are both null.
- [ ] **ALWAYS dirty the buffer before timing a transform.** A read-only ladder understates
      host-memory cost and already produced one wrong "dead end" conclusion this project.
- [ ] **Interleaving is not rotating.** Fixed-order arms confound position with arm identity.
      A first-listed arm winning every cell is the signature. Rotate with
      `arms[(it + k) % arms.size()]`. The effect survived here and grew 7.17 → 10.94 µs at 4 MB.
- [ ] **A name is not evidence.** `madvise(MADV_HUGEPAGE)` returning 0 means the kernel took a
      hint, not that it promoted anything. Verify via `/proc/self/smaps` `AnonHugePages`. An
      arm labelled THP held zero huge pages below a 2 MB payload.
- [ ] GPU clocks **cannot** be locked on GB10 → every GPU-side latency is DVFS-sensitive.
      **Never compare across runs.** Interleave and rotate arms within a rep, use paired tests.
- [ ] Three measurement artifacts have already burned this project: async timers measuring
      enqueue rather than work, thermal drift across runs, and single-rep variance inside an
      otherwise correctly interleaved run. Every new claim needs ≥3 reps and a paired test.
- [ ] Spark system wall clock is unreliable (date jumps); use same-host send/recv deltas.
- [ ] The Spark repo at `/home/nitest/daqiri_gpu` is an **scp mirror, not a clone**, so there is
      no git metadata there. Always pass `GITSHA=` explicitly to the sweep scripts.
- [ ] `bench_fft_memsrc --sizes` is in **samples, not KB**. 1048576 samples = 4 MB payload.
- [ ] `HugePages_Total: 0` on the Spark, so `MAP_HUGETLB` is impossible without root. THP at
      2 MB is the only huge-page mechanism reachable as `nitest`. Moot now: page size is
      innocent.

---

## Environment notes (this sprint)

- **Build:** `cmake --build ~/daqiri_gpu/build_grpc --parallel 16 --target bench_grpc_server`.
  The build dir is configured with `-DCMAKE_CUDA_ARCHITECTURES=121`.
- **Runtime:** `export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:$LD_LIBRARY_PATH"`.
- **Between runs:** `pkill -9 -f bench_grpc_server; rm -rf /tmp/iceoryx2; rm -f /dev/shm/iox2_*`.
- SSH to Spark: scp a script file and run `bash /tmp/x.sh`; inline multi-line commands get
  mangled. Use full paths to `ssh.exe`/`scp.exe` on Windows.
- `.gitattributes` forces LF on `*.sh` / `*.py` so Windows checkouts do not break bash on Spark.

