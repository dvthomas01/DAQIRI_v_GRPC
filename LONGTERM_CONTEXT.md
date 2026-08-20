# Long-Term Context — Architectural Reference
**Project:** DAQiri GPU FFT Pipeline Benchmark  
**Updated:** 2026-08-20  
**Precursor project:** gRPC / gRPC Direct benchmark — all 20 milestones complete 2026-07-08

> **This file is committed now.** It was gitignored while `handoff_roce_2026-08-06.md`,
> `presentation/HANDOFF.md` and `scripts/find_spark.sh` all pointed readers at it.

---

## Key findings (the RDMA transport, 2026-08-20)

- **The registration penalty has a domain.** `cudaHostAlloc` beats `cudaHostRegister` by about
  10.94 µs of transform time **at 4 MB**, and by nothing at all below about 1 MB. Quoting the
  figure without the payload size overstates it for every small message. No `cudaHostRegister`
  flag recovers any of it: `Default`, `Portable` and `WriteCombined` are all null and
  `ReadOnly` is refused by the driver.
- **`WriteCombined` really does take a different driver path and still does not matter.** Its
  allocation is backed by `/dev/nvidiactl` with vmflags `rd wr sh mr mw me ms de dd mm`, where
  the plain allocation shows `/dev/zero (deleted)` with `rd wr sh mr mw me ms`. Same timing.
  That is a stronger refutation than "the flag did nothing".
- **Bytes have crossed the cable into GPU-readable memory.** The PXI RDMA-writes over RoCE into
  a `cudaHostAlloc`'d pool on the Spark and cuFFT transforms in place, verified spectrally over
  31,800 messages with zero completion errors. Raw libibverbs RC queue pairs with a TCP side
  channel; `rdma_cm` was deliberately not used because perftest is the only RDMA traffic ever
  demonstrated between these boxes.
- **A correctness checker is worthless until you have watched it fail.** Launching cuFFT before
  observing the RDMA completion must break verification, and proving that came before trusting
  any green run. It needs two things to be capable of failing: a payload that varies per
  message (else stale bytes verify clean) and a poison pattern written before each message
  (else absent data verifies clean).
- **Checker sensitivity can be size-dependent.** With ordering deliberately broken, 1 of 20
  16 KB messages still passed, because a small write can land inside the launch window. A
  one-message ordering test at a small payload would have certified a program with the race
  fully present.
- **easyrdma allocates the landing buffer by default, which is the wrong end of the finding
  above.** `easyrdma_ConfigureBuffers` makes the library allocate and register; the caller then
  gets a pointer into memory it did not allocate. `easyrdma_ConfigureExternalBuffer` takes a
  caller-supplied pointer instead, which is the seam that lets a `cudaHostAlloc`'d pool be the
  landing zone.
- **And the seam works.** Gate 5, `scripts/gate5_extbuf.cu`:
  `easyrdma_ConfigureExternalBuffer` accepts a 64 MiB `cudaHostAlloc` pool, the payload lands
  at the caller-chosen offset with the rest of the pool untouched, and a GPU kernel sums the
  bytes in place through the device pointer and matches the CPU. Offsets need no alignment; an
  unaligned 1048577 works. The control with stock `ConfigureBuffers` lands outside the pool
  while still transferring, so it is a live control rather than a silent one.
- **External buffers are a different protocol, not a flag on the same one.** Three differences,
  each of which cost a debugging cycle or would have:
  - Completion arrives **only by callback**. `easyrdma_AcquireReceivedRegion` throws
    `InvalidOperation` (-734004) because `RdmaBufferQueue::WaitForCompletedBuffer` refuses
    outright when `putBackToIdleOnCompletion` is set, which it is for external queues.
  - There is **no release call**. The slot goes back to idle when the callback fires;
    `easyrdma_Property_UserBuffers` reads 0 immediately after. `QueueExternalBufferRegion` is
    the only re-arm, and it is also what sends credit, because `ConfigureExternalBuffer` does
    not set `autoQueueRx` and so never posts receives for you.
  - Teardown needs `easyrdma_CloseFlags_DeferWhileUserBuffersOutstanding`. Without it, closing
    a session with one of our regions still queued gives `double free or corruption`.
- **RX polling and external buffers are mutually exclusive.**
  `RdmaConnectedSessionBase.cpp:153` throws `OperationNotSupported` (-734026) when `usePolling`
  is set, confirmed empirically. This is a benchmark design constraint, not a detail: an
  external-buffer arm cannot poll, so comparing it against a polling stock arm confounds
  allocation ownership with interrupt wakeup, and the wakeup may be the bigger term.
- **A prediction made before the run is worth more than the run.** The polling exclusivity was
  read out of the easyrdma source and written down as an expected failure *before* Gate 5 ran,
  then came back at exactly -734026. That is what licenses trusting the rest of the same source
  reading; a gate composed only of things expected to pass would not have.

## Key findings (measurement methodology, 2026-08-19)

These are the durable lessons. Several headline numbers on this project turned out to be
measurement artifacts, and each one survived for a while because it was plausible.

- **Include a control that should NOT move.** When the RoCE MTU was raised, the 4 MB write got
  4.9% faster. On its own that is indistinguishable from drift between two runs. The 2-byte
  message was measured in the same pair of runs, and it could not possibly be affected because it
  fits in one packet either way. It did not move. That is what makes the 4 MB delta a
  measurement rather than a coincidence. A control that stays still is cheaper than a repeat run
  and proves more.
- **Change one thing and measure twice, even when you are confident the change is an
  improvement.** The MTU mismatch was obviously wrong and obviously worth fixing. Fixing it
  before taking a baseline would have produced one number with no way to attribute it, and would
  have left nothing in hand if the change had misbehaved. Baseline, change, remeasure.
- **Test the negative case in the same program.** The gate that proved the NIC accepts
  CUDA-pinned host memory also attempted the identical registration on device memory and got a
  rejection. The positive result alone supports "we chose host memory". The pair supports "host
  memory is the only option this hardware offers", which is a much stronger claim and cost about
  fifteen extra lines.
- **Write down machine state that does not survive a reboot, at the moment you create it.** The
  PXI needs a manually assigned IP and a manually raised MTU before any RDMA works, and both
  vanish on reboot. There was already precedent: the Spark's address had been set ad hoc during
  earlier work and was lost, and rediscovering it cost time. The symptom presents as a dead link
  that looks like a hardware fault and is actually a missing line.
- **When a build dependency has no skip flag, build it rather than stub it, if the thing it does
  touches what you are measuring.** perftest would not configure without libpci, which was absent.
  libpci is used in exactly one function, to detect PCIe relaxed ordering. Stubbing it would have
  compiled fine and silently changed a setting that affects RDMA write performance, which is the
  quantity under test. Building it into a user directory took a few minutes and left the tool
  honest.
- **`#ifdef` on an enumerator is always false.** A capability probe guarded a driver query with
  `#ifdef CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED`. That is an enum constant, not a macro, so the
  guard silently skipped the query and the program cheerfully reported "not in this CUDA header"
  for an attribute that was present. Query the attribute and distinguish "driver says
  unavailable" from "we never asked".
- **A benchmark that never dirties the buffer understates host memory, and can invert a
  conclusion.** The memory-kind ladder was read-only and declared the whole question dead. Add
  the CPU write that every real pipeline performs and the arms separate by 10.94 µs at a 4 MB
  payload with p = 6.1e-05. The read-only caveat had been written down and not acted on.
  **Always measure the producer write and the transform together;** a change that slows the
  write and speeds the
  transform looks like a pure win when only half the window is timed.
- **Interleaving is not rotating.** Interleaving at fine grain removes drift between arms, but
  with a fixed order the arm listed first always runs in the same slot, so position becomes a
  hidden variable perfectly correlated with arm identity. The signature is a first-listed arm
  winning every single cell. Rotate the starting arm: `arms[(it + k) % arms.size()]`.
- **A name is not evidence; verify the mechanism you claim to be testing.** An arm labelled
  `THP` had been reported as a huge-page test on the strength of `madvise(MADV_HUGEPAGE)`
  returning 0. That return value means the kernel accepted a hint. `/proc/self/smaps`
  `AnonHugePages` showed the arm held zero huge pages below a 2 MB payload, so its null result
  said nothing at all about page size.
- **Record predictions before the data exists.** The spin-vs-block probe predicted a
  large-payload crossover in a header comment. Blocking lost at all six sizes. A documented
  refutation is worth more than a quietly dropped hypothesis.
- **Interleaving arms removes bias *between* arms. It tells you nothing about how much a single
  measurement moves.** A correctly interleaved single-rep run reported a 2.91 µs gap at 4 MB; the
  repeated run put it at 8.10 µs, because that run's DAQiri number happened to land at 69.07
  instead of 62.31 while gRPC barely moved. **≥3 reps for any new claim, with a paired test.**
- **Never compare across runs on a box where GPU clocks cannot be locked.** An earlier 12.2 µs
  gap figure was thermally contaminated: the two arms were measured in separate runs at
  different DVFS states.
- **Async CUDA calls hide their cost in the next synchronization.** A stage timer around
  `cudaMemcpyAsync` read 3–5 µs while the real 77 µs surfaced inside the FFT's
  `cudaEventSynchronize`. Measure `wall(call) − gpu_event`.
- **Difference inside the paired cell, then take the median. Not median-then-difference.** The
  identity `(A_e2e − B_e2e) = (A_fft − B_fft) + (A_resid − B_resid)` stays exact that way, and
  drift common to both arms cancels.
- **Guard every arm against silently becoming a duplicate of its control.** `--zc-bigreg` falls
  back to exact-span registration when the rounded-down base runs off the front of the mapping.
  It did so on 2 of 3 reps at 4 MB. Without a warning printed and grepped, that run would have
  read as "tested, no effect" while two of fifteen cells tested nothing at all.
- **Guard destructively, not politely.** A probe that faults should drop its arm and say so, not
  kill the sweep. A `sigaction(SIGSEGV/SIGBUS)` plus `sigsetjmp` probe caught that GB10 device
  memory is not CPU-writable, and the sweep completed and reported it.
- **Correctness before timing, always.** A failed kernel launch leaves the destination untouched,
  which reads as a fast result. One E3 run "won" at 53.9 µs with an all-zero spectrum.
- **A missing binary prints nothing and reads exactly like a negative result.** Bit us twice
  during network diagnosis on the PXI (`ssh-keyscan`, `nc`).
- **`pgrep -f` matches the ssh command line that invoked it.** Use the bracket trick,
  `pgrep -af '[h]eadline_sweep'`, or you will conclude a finished run is still going.

## Key findings (where the gRPC/DAQiri gap actually lives, 2026-08-18)

- **Decompose latency into `e2e − fft_exec` ("residual") before optimizing anything.** This
  located the original gap and it still structures everything. gRPC's residual is now flat at
  5.5–6.7 µs against DAQiri's 4.9–5.0 across a 256× size range. The residual problem is solved.
- **What remains is inside cuFFT, and it is per-byte.** ~80 % of the 8.10 µs gap at 4 MB is
  transform time, growing 0.77 → 6.40 µs from 16 KB to 4 MB. Transport is 0.3 to 1.7 µs.
- **Both pipelines run genuinely the same transform.** Verified by code read, not benchmark:
  same `cufftPlan1d` R2C, same n, batch 1, default strides, out-of-place in both, no
  `cufftSetWorkArea` in either, one JIT warmup each, plan built once. **Both write output to
  `cudaMalloc`'d device memory**, so the placement penalty is paid once on the input side only.
- **Memory-source ladder for cuFFT on GB10 (4 MB R2C, p50, paired within cells):** `cudaMalloc`
  device **45.15** < `cudaHostAlloc`'d pinned MR (DAQiri) **57.36** < `cudaHostRegister`'d
  shmem slot (ours) **63.76** µs. Where the input lives is worth ~19 µs. 18/18 cells,
  p = 7.6e-06. In-place zero-copy is NOT automatically fastest; it wins here only because the
  copy that would avoid it costs more than the slower read.
- **The copy engine reads mapped host memory at ~52 GB/s**, and D2D-from-mapped and
  H2D-from-pinned hit the identical wall, so the API choice does not matter. Consequence worth
  stating plainly: **staging into `cudaHostAlloc`'d memory to buy the faster FFT costs ~77 µs at
  4 MB to save 6.40. Dead at every size.** A grid-stride SM kernel roughly doubles throughput to
  ~102 GB/s, still nowhere near the ~170 it would need to pay off.
- **It is not mapping granularity.** Rounding registration up to whole 64 KB GPU pages, exactly
  what DAQiri's MR does, over the very same host memory, changes nothing: 9/15 cells, p = 0.61,
  measured at 3 reps × 5 sizes interleaved. Remaining suspects are the arena's underlying page
  size and NUMA/physical placement.
- **`cudaHostRegisterReadOnly` is not supported on GB10** ("operation not supported").
  `cudaHostRegisterMapped` is what we use.
- **Structural difference that explains DAQiri's edge:** DAQiri does its expensive memory setup
  ONCE at init (one `cudaHostAlloc` region, one `ibv_reg_mr`, slots strided by 64 KB so alignment
  is correct by construction, lock-free ring). The gRPC bench does per-message registration.

## Key findings (gRPC-Direct optimization, 2026-08-07)

- **Decompose latency into `e2e − fft_exec` ("residual") before optimizing anything.** DAQiri's
  residual is flat at ~4.9 µs from 16 KB to 4 MB; gRPC's grew 8.1 → 81.5 µs. A flat residual is
  a fixed floor (CUDA event record + sync + clock reads); a growing one is per-byte work that
  does not belong. This single view located the entire gap.
- **cuFFT accepts an 8-byte-aligned R2C input.** The server gated in-place FFT on
  `(dptr & 15) != 0` and assumed protobuf's `RepeatedField<float>` store was 16-byte aligned.
  It is 8. So 100 % of messages took an unnecessary device-to-device realign copy worth ~77 µs
  at 4 MB. Removing it: 4 MB e2e 127.2 → 75.9 µs (1.67×). **Probe the API at runtime instead of
  hard-coding an alignment rule.**
- **Async CUDA calls hide their cost in the next synchronization.** `cudaMemcpyAsync` only
  enqueues, so a stage timer around it read 3–5 µs while the real cost (77 µs) surfaced inside
  the FFT's `cudaEventSynchronize`. Measure `wall(fft_call) − gpu_event(fft)` to catch this.
- **Memory-source ladder for cuFFT on GB10 (4 MB R2C, p50):** `cudaMalloc` device memory
  **45.6 µs** < `cudaHostAlloc`'d pinned host (DAQiri) **58.8 µs** < `cudaHostRegister`'d heap
  block (ours) **68.8 µs**. *(These cross-run figures were retracted, then re-established by the
  paired 2026-08-18 sweep at 45.15 / 57.36 / 63.76. The retraction was right about the evidence
  and wrong about the conclusion: the effect is real.)*
- **The copy engine is slow at reading mapped host memory: ~52 GB/s.** D2D-from-mapped and
  H2D-from-pinned hit the identical wall, so the API choice does not matter. A grid-stride SM
  kernel roughly doubles it to ~102 GB/s, still not enough to beat reading in place.
- **`cudaHostRegisterReadOnly` is not supported on GB10** ("operation not supported").
  Rounding registration up to 64 KB GPU pages (what DAQiri does) changed nothing. *(Re-tested
  properly on 2026-08-18 under the interleaved/repeated methodology. Still nothing: 9/15,
  p = 0.61. This one held up.)*
- **DGX Spark's GB10 is compute capability 12.1 (sm_121), not sm_90.** The repo hard-coded
  `CMAKE_CUDA_ARCHITECTURES=90`, so every custom kernel failed to launch with
  `cudaErrorNoKernelImageForDevice` — silently, because cuFFT ships fat binaries and kept
  working. A failed launch leaves the destination untouched, which reads as a fast but wrong
  result. **Always `CUDA_CHECK(cudaGetLastError())` right after a kernel launch.**
- **Structural difference that explains DAQiri's edge:** DAQiri does its expensive memory setup
  ONCE at init (one `cudaHostAlloc` region, one `ibv_reg_mr`, slots strided by 64 KB so
  alignment is correct by construction, lock-free ring, dedicated CUDA stream, non-blocking
  event-based completion). The gRPC bench does per-message work behind a global mutex and
  blocks on `cudaEventSynchronize`.


## Key findings (RoCE true zero-copy + two-machine link, 2026-08-06)

- **Two-machine Spark↔PXI 50 G RoCE link is LIVE and RDMA-verified** (`rping` RC read/write,
  10/10, clean disconnect). Spark `enp1s0f0np0` `192.168.20.1/24` ↔ PXI `enp117s0`
  `192.168.20.2/24`. The PXI port had only a link-local `169.254.x` addr (subnet was dead)
  until we assigned it a real IP. PXI-facing Spark port confirmed by ARP.
- **RoCE RC preserves whole message boundaries** (1 work-request = 1 payload, scatter-gather
  DMA) → delivers every payload intact to 4 MB, 0 drops. The old TCP socket test shim was a
  BNO-style one-recv()=one-packet path that fragmented at ~128 KB (kernel `tcp_rmem` default),
  which is why socket-DAQiri fell off a cliff there.
- **GB10 unified/coherent NVLink-C2C:** pinned host pointer == device pointer → zero-copy is a
  true in-place cuFFT with 0 µs H→D transfer. (This GPU is GB10 / Grace-Blackwell, ARM host —
  NOT GH200; `nvidia-smi` confirms GB10, and clocks CANNOT be locked here.)
- **RoCE vs gRPC-Direct (4 MB sweep, matched N=200/W=50/pace 400 µs):** RoCE lower latency every
  size (≈1.5× @16 KB → 2.0× @4 MB p50), tighter p99, 0 drops. gRPC shmem now also reaches 4 MB
  with the same ~2.6× zero-copy speedup but drops small buffers and has a fatter tail.
- **Access:** root on the PXI (`root@10.198.65.118`); no passwordless sudo on Spark (`nitest`).

## Key findings (Pipeline B transport comparison, M9)

- **Transport metric = wire latency** (`send_timestamp_ns` → server receive), NOT
  H→D copy latency. H→D is byte-identical code in both transports and is dominated
  by GH200 **GPU DVFS** (SM clock idles 208 MHz, boosts 2405 MHz) during paced idle
  gaps — so it cannot discriminate transports. Compare transports at **matched pace**.
- **Result:** shmem (iceoryx2) transport = 24–65 µs vs standard gRPC 147–213 µs
  (3–8× lower). Tradeoff: standard = 100 % delivery (backpressure blocks sender);
  shmem = ~97 % (lossy, non-blocking ring). shmem trades ~3 % loss for low latency.
- **Pipeline A (DAQiri DMA)** is ~order-of-magnitude faster E2E than either B
  transport; Pipeline B's value is architectural (decoupled, network-transparent).
- **GPU clocks cannot be locked** here (`nvidia-smi -lgc` needs privileges we lack).
- **Plotting env:** local `py` (Python 3.14 + matplotlib 3.11.1); Spark `python3`
  (3.12) has no matplotlib — pull CSVs local and plot with `scripts/plot_m9_comparison.py`.

---

## People & Access

| Person | Role | GitHub |
|---|---|---|
| Dami Thomas | NI Intern (Summer 2026) | `dvthomas01` |

**GitHub auth:** NI org requires SAML SSO. PATs must be authorized at  
`github.com/settings/tokens` → Configure SSO → Authorize National Instruments.  
Use token in URL: `https://dvthomas01:<TOKEN>@github.com/ni/...`  
Do not commit tokens.

---

## Key Repositories

| Repo | URL | Notes |
|---|---|---|
| NVIDIA DAQiri | `https://github.com/nvidia/daqiri` | Public; already installed on Spark |
| grpc-direct | `https://github.com/ni/grpc-direct` | Private — NI SSO PAT required |
| easyrdma | `https://github.com/ni/easyrdma` | NI org; built on both arches |
| grpc-perf | `https://github.com/ni/grpc-perf` | Reference |
| Prior benchmark | `C:\Users\doluwada\benchmark\` (local) / `~/benchmark/` (Spark) | All 20 milestones done |

---

## Hardware

### DGX Spark — `spark-ac69`
| Property | Value |
|---|---|
| Reach by | **hostname** `spark-ac69.ni.corp.natinst.com` (mgmt IP is DHCP; currently 10.198.65.106 — the old 10.1.30.230 is DEAD) |
| OS | DGX OS (Ubuntu 24.04), **aarch64 (ARM)** |
| GPU | **NVIDIA GB10** (Grace-Blackwell), driver 580.95.05 — clocks NOT lockable |
| Login | `nitest` (key auth, NO password; **NO passwordless sudo**) |
| SSH | `ssh nitest@spark-ac69.ni.corp.natinst.com` |
| Management NIC | `enP7s7` at 10.198.65.106 |
| RoCE NIC (to PXI) | `enp1s0f0np0` (`rocep1s0f0`, LEFT QSFP) → **192.168.20.1/24** (50G) |
| Other 50G port | `enP2p1s0f0np0` (`roceP2p1s0f0`) — link-up, NOT the PXI link |
| CUDA | CUDA 13 at `/usr/local/cuda-13/bin` |
| Repo on Spark | `/home/nitest/daqiri_gpu` (build_grpc/ has gRPC bench binaries); DAQiri SDK at `/home/nitest/daqiri` |
| Python | 3.12.3 |
| Rust | 1.96.0 (rustup) |
| Compilers | clang 18, llvm 18, cmake, protoc, pkg-config, nvcc |

**Pre-installed (from prior benchmark):**
- `~/grpc-direct/` — repo cloned, Rust core built release, interceptor patches applied
- `~/benchmark/` — prior gRPC benchmark harness (reference)
- `~/daqiri/` — DAQiri SDK (installed M19; RDMA loopback tested on Spark)
- `~/grpc-bench-env/` — Python venv

### NI PXIe-8881 — `NI-PXIe-8881-31F6D74`
| Property | Value |
|---|---|
| Management IP | **10.198.65.118** (mgmt NIC `eno0`) |
| OS | NI Linux RT (x86_64), kernel 6.12-rt, run mode |
| Login | `root@10.198.65.118` OR `admin@10.198.65.118` (key auth, NO password, **ROOT shell**) |
| SSH | `ssh root@10.198.65.118` |
| RoCE NIC (to Spark) | `enp117s0` (`rocep117s0`) → **192.168.20.2/24** (50G DAC) — runtime IP, not persisted |

> **Note:** The Spark↔PXI 50 G RoCE link is now live and RDMA-verified (see Key findings).
> We have **root on the PXI**, so IP assignment there is done directly via `ip addr add`.

---

## Network Topology

```
Windows Laptop (this machine)  — corp LAN / Wi-Fi
    |
    |-- SSH --> DGX Spark  (spark-ac69, mgmt 10.198.65.106) ──┐ 50G RoCE 192.168.20.1 (enp1s0f0np0)
    |                                                          │  direct DAC cable, RDMA VERIFIED
    |-- SSH --> NI PXI-8881 (mgmt 10.198.65.118, ROOT)     ───┘ 50G RoCE 192.168.20.2 (enp117s0)
                (mgmt on shared 10.198.65.x lab subnet)
```

### Settling whether the Spark is alive

ICMP is filtered on the lab subnet, so `ping` from Windows proves nothing. The reliable test is
ARP from the PXI, which sits on the same L2 segment. **Flush first.** On 2026-08-20 a stale
entry reported `10.198.65.106 dev eno0 lladdr 4c:bb:47:2e:ac:69 DELAY`, the Spark's own
management MAC, on a box that was actually off the network. After `ip neigh flush dev eno0` and
a fresh ping the same lookup returned `FAILED`.

`scripts/find_spark_arp.sh` does the whole thing: flush, sweep the /24, report every host
answering with an NVIDIA OUI, and say explicitly whether `4c:bb:47:2e:ac:69` is present. A
sweep distinguishes "moved to a new DHCP lease" from "off the network", which a single-address
check cannot. Beware `4c:bb:47:2a:b7:*`: those are other DGX Sparks in the same lab.

---

## RDMA Fabric (proven, built)

- **CURRENT (2026-08-06):** 50G RoCE link Spark `enp1s0f0np0` = `192.168.20.1/24` ↔ PXI
  `enp117s0` = `192.168.20.2/24`. RDMA verified with `rping` (RC read/write, 10/10).
- PXI IP is runtime-only. **Corrected 2026-08-20: it does not only die on a PXI reboot, it dies
  whenever the carrier flaps, which means every time the Spark is power-cycled.** Observed with
  the PXI at `up 13 days` and no reboot of its own: `192.168.20.2/24` had been replaced by a
  `169.254/16` link-local address, while `mtu 9000` survived. Recovery is
  `scripts/roce_restore_pxi.sh` (root on PXI), which is `ip addr add 192.168.20.2/24 dev
  enp117s0` plus the MTU, and then re-reads the GID indices. To persist: NI MAX or `connmanctl`.
  **Check this after every Spark reboot, not just after a PXI reboot**, because the failure is
  silent: the link stays UP, the ibverbs port stays ACTIVE, and only the route is gone.
- **The GID index is a position in a list, not an identity. Read it, never quote it.** After the
  2026-08-20 recovery the PXI's RoCE v2 IPv4 GID was back at index 5, which is what
  `rdma/rdma_fft_client.cc` defaults to. That is only true because the stale link-local address
  is *also* still on the interface, occupying indices 2 and 3 ahead of it. Flush the link-local
  and `192.168.20.2` slides down to index 3. The Spark's is index 3 for the same reason in
  reverse: it has only the one address. Both scripts print the indices with the address each one
  carries; use that output rather than memory.
- (Historical: an earlier 192.168.10.x link on the 1G ports is obsolete after a room move.)
- easyrdma built on BOTH arches (`core/` subdir only: `cmake .. -DCMAKE_BUILD_TYPE=Release; make`)
- grpc-direct rebuilt with `--features rdma` on BOTH machines
- **Hardware ceiling:** 5.785 GB/s = 92.6% of 50G line rate (1024-byte IB MTU / 1500-byte Ethernet MTU)

---

## Prior Benchmark — Key Results (gRPC Direct, complete 2026-07-08)

| Scenario | Transport | Result |
|---|---|---|
| Localhost Echo (C++ interceptor) | grpc-direct shmem | **3.3 µs p50** (281× faster than std gRPC) |
| Localhost Echo (native Rust floor) | grpc-direct shmem | 2.78 µs p50 |
| Streaming throughput zero-copy | grpc-direct shmem | **23.59 GB/s** |
| RDMA Echo (machine-to-machine) | grpc-direct RDMA | **36.8 µs p50** (29× faster than TCP) |
| RDMA throughput vs line rate | grpc-direct RDMA | **5.775 GB/s** (99.8% of ceiling) |
| DAQiri RDMA loopback (Spark) | DAQiri RDMA | ~5.785 GB/s |
| **grpc-direct RDMA vs DAQiri** | both | **< 1% delta** |
| Standard gRPC TCP baseline | TCP | 929–1086 µs Echo p50, 1.78 GB/s streaming |

---

## DAQiri Architecture Notes

- DAQiri is NVIDIA's purpose-built DAQ transport framework using RDMA to land data directly in CUDA device memory
- SDK at `~/daqiri/` on Spark; config pattern: `~/benchmark/scripts/daqiri_bench_rdma_loopback_spark.yaml`
- Key loopback IPs for Spark self-test: `10.30.30.1` and `10.30.30.2` (two IPs on RoCE NIC)
- M19 of prior benchmark verified DAQiri RDMA throughput matches grpc-direct RDMA within 1%
- Synthetic injection: feed the DAQiri **software buffer stage** directly — no hardware required

---

## gRPC Direct Architecture Notes (C++)

### Transport hierarchy (relevant for Pipeline B)
```
grpc_direct::SHARED_MEMORY     — iceoryx2 IPC, zero-copy same-host
grpc_direct::TCP                — grpc-direct TCP framing
grpc_direct::TCP_LOW_LATENCY    — TCP + TCP_NODELAY
grpc_direct::RDMA               — easyrdma over 50G RoCE
grpc_direct::RDMA_LOW_LATENCY   — RDMA + poll mode
```

### The RDMA transport is implemented, despite what the header says

`include/grpc_direct.h` and the doc comment at `src/lib.rs:1215` both still say
`Rdma / RdmaLowLatency : not yet implemented, returns NULL`. **That comment is stale.**
`src/lib.rs` contains `RdmaServerBackend`, `RdmaClientBackend`, a full easyrdma FFI block and
live dispatch arms for `Transport::Rdma`. Verified by reading the source, 2026-08-20.

How it actually behaves, which matters more than that it exists:

- **Two unidirectional sessions per connection**, because RDMA connections are one-way. The
  server listens on `port` for `DIRECTION_RECEIVE` and `port + 1` for `DIRECTION_SEND`.
- **`RDMA_MAX_FRAME_SIZE` = 16 MiB, `RDMA_MAX_CONCURRENT` = 4.** Those are the frame ceiling
  and the queue depth, and 4 is where backpressure begins.
- **Receive is zero-copy but library-allocated.** `grpc_direct_server_receive` hands out
  `region.buffer` directly, which is easyrdma's *internally allocated* memory. Note that
  `docs/RDMA_TRANSPORT.md` claims received regions are "copied into a thread-local buffer";
  the code does not do that, so the doc and the source disagree and the source wins.
- **A region is held until the next receive call.** `server_receive` begins by releasing the
  previously-held region, then acquires the next. So message N's buffer stays valid exactly
  until you ask for message N+1, which is a one-in-flight ownership model regardless of the
  queue depth of 4.

### The library we are actually running is a fork, and here is what is in it

Audited 2026-08-20. `/home/admin/grpc-direct` on the PXI has no `.git`, so provenance was
established by hashing every file against a fresh clone of `https://github.com/ni/grpc-direct.git`.
Base is upstream HEAD `2d404a5` (2026-06-11); **125 of 127 tracked files are byte-identical**.
The only modified source file is `src/lib.rs` at +529/-31. The four `lib.rs.bak*` files are
monotone snapshots and no function defined in any of them is missing from the current file, so
nothing was tried and reverted. Reproduce with `scripts/diff_grpc_direct_upstream.ps1` and
`scripts/audit_libr_baks.sh`. The full diff is vendor code and is deliberately not committed;
it lands at `data/lib_rs_vs_upstream.diff` when you run the scripts.

The changes, and why each matters:

- **Upstream's RX polling flag silently does nothing.** Upstream sets `PROPERTY_USE_RX_POLLING`
  *after* `easyrdma_ConfigureBuffers` and ignores the return code; easyrdma rejects the property
  once buffers are configured. The fork sets it first and checks. Consequence for benchmarking:
  an `rdma-stock` arm built from unmodified upstream would not be polling even when asked, which
  is a confound. Build that arm from the fork with our own changes disabled.
- **Disconnect handling diverges.** The fork wraps `AcquireReceivedRegion` in a retry loop that,
  on `ERROR_DISCONNECTED`, tears the session down and blocks in `easyrdma_Accept` with
  `TIMEOUT_INFINITE`. Upstream returns an error. So a peer dropping out mid-run appears as an
  indefinite stall in the receive path, not as a failure. Delivered-count accounting catches it.
- **`GRPC_DIRECT_RDMA_LOCAL`** overrides the client's local bind address. Without it the client
  binds to the remote address, which cannot work cross-machine. Needed for any two-box run.
- **Zero-copy response and a pipelined streaming API** were added: `response_reserve` /
  `response_commit` serialize in place on the send region, and six more `extern "C"` functions
  implement depth-K streaming.
- **No external-buffer API is called anywhere**, in upstream, the fork, or any `.bak`. Neither
  `easyrdma_ConfigureExternalBuffer`, `easyrdma_QueueExternalBufferRegion`,
  `easyrdma_ReleaseUserBufferRegionToIdle`, `easyrdma_Property_UserBuffers` nor
  `easyrdma_CloseFlags_DeferWhileUserBuffersOutstanding`. This is the seam Phase 3 needs and it
  is unbound, so it has to be added rather than enabled.
- **A suspected slot leak, found in passing and not fixed.** In `grpc_direct_client_stream_go`,
  a failed `easyrdma_QueueBufferRegion` returns without releasing the acquired region, losing
  one slot from a pool of four. Not on the Phase 3 path. Recorded so it is not later
  rediscovered as a mystery hang.

**When diffing a Linux tree against a Windows clone, turn line-ending translation off.** The
first run of this comparison reported 123 of 127 files modified. That was `core.autocrlf`
checking the clone out as CRLF, not a finding. `git -c core.autocrlf=false -c core.eol=lf clone`
drops it to 2. A comparison that says almost everything changed is describing its own
configuration.

### The Spark and the PXI are not running the same grpc-direct

Compared 2026-08-20 with `scripts/hash_grpc_direct.sh` and
`scripts/diff_grpc_direct_spark_vs_pxi.ps1`. 144 files identical, 2 different, 8 Spark-only.
`src/lib.rs` is byte-identical on both (md5 `b61b26dae6ecfbf0bfae2103881f45ab`), so the Rust
matches. The divergence is in C++ and Go, and the PXI audit above recorded both files as
untouched:

- `cpp/client_interceptor.cc`, +16/-5. Adds a `firstRecv_` flag separate from `isFirstMessage_`
  and calls `methods->FailHijackedRecvMessage()` on both end-of-stream paths, plus an early exit
  when the stream already ended. Upstream calls it on neither, so a hijacked server-streaming
  `Read()` would not terminate cleanly.
- `plugin/cmd/protoc-gen-grpc-direct/gen_cpp.go`, 2 lines. `_actual` → `_response` in the
  generated `Direct<Msg>` move constructor and move assignment. Upstream emits a member that
  does not exist, so upstream's generated C++ does not compile.

**Why this matters more than its size suggests.** We link `libgrpc_direct_cpp.a` from
`GD_BUILD`, so `cpp/client_interceptor.cc` is inside every gRPC number produced on the Spark,
and that file is not the file that was audited. The audit ran on the PXI because that was the
copy without a `.git`; the machine we benchmark on is the one carrying extra uncommitted edits.
Fork from the **Spark's** tree, or from both with the difference stated.

**The Spark's copy does have a `.git`**, HEAD `2d404a5` on `main` tracking `origin/main`, with
nothing committed locally. Every fork change is an uncommitted working-tree edit. It confirms
the PXI's hash-reconstructed base commit by a second, independent method.

Also Spark-only: `.cargo/config.toml` pinning `linker = "x86_64-linux-gnu-gcc"` for
`x86_64-unknown-linux-gnu`. Inert natively on aarch64; it bites the moment anything is
cross-built for the PXI.

**Its `.git/config` had a GitHub personal access token in the remote URL in plaintext.** Do not
copy that directory, do not commit anything derived from `git remote -v`, and scrub any probe
output before it lands in `data/`. Flagged to the user 2026-08-20 for revocation.

### C++ interceptor pattern (from prior benchmark)
```cpp
// Client side: inject at channel creation
auto interceptors = std::vector<...>{
    std::make_unique<grpc_direct::DirectTransportInterceptorFactory>(transport)
};
auto channel = grpc::CreateCustomChannel(
    server_addr, grpc::InsecureChannelCredentials(),
    grpc::ChannelArguments{});
// ... apply interceptors
```

### Known issues (patched in prior benchmark)
- 3 streaming interceptor bugs fixed via `~/benchmark/scripts/patches/`
- Patches must be re-applied after any grpc-direct source reset
- `patch_fix_member.py`, `patch_fix2b.py`, `patch_eos.py`, `patch_fail_recv.py`, `remove_traces.py`

---

## CUDA / cuFFT Notes

- DGX Spark is ARM aarch64; CUDA toolkit installed (nvcc available)
- cuFFT R2C plan for real float32 input: `cufftPlan1d(&plan, N, CUFFT_R2C, 1)`
- Execute: `cufftExecR2C(plan, d_float_in, d_complex_out)`
- Output: `cufftComplex[N/2+1]`; magnitude of bin k = `sqrtf(re²+im²) * 2/N`
- Frequency of bin k = `k * sample_rate / N`
- Time CUDA kernels with `cudaEventRecord` / `cudaEventElapsedTime`
- Profile with `nsys profile --trace=cuda,nvtx ./benchmark` and `ncu --kernel-id ::cufftExecR2C: ./benchmark`

---

## Build Notes (Spark — aarch64)

```bash
# Activate Python venv (if needed)
source ~/grpc-bench-env/bin/activate

# Standard CMake configure + build pattern
mkdir -p ~/daqiri_gpu/build && cd ~/daqiri_gpu/build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# Cross-compile for PXI (x86_64) — only needed for Pipeline B server on PXI
cmake .. -DCMAKE_TOOLCHAIN_FILE=../toolchains/pxi-x86.cmake
```

---

## Key Lessons from Prior Benchmark (apply here)

1. **Python polling sleep was the bottleneck** (~25× speedup from removing `time.sleep(0.0001)`) — this project is C++ only, so not a concern, but keep server loops non-blocking.
2. **CPU pinning matters on non-RT kernels** — taskset + chrt cut Spark's std gRPC p50 from 1118 µs → 74 µs. Consider pinning benchmark threads.
3. **Zero-copy only wins in C++** — Python has residual memmove. Our C++ cuFFT path naturally avoids extra copies if CUDA device pointers are registered with DAQiri.
4. **Container overhead is zero** for shmem path with `--ipc=host`. Relevant if pipeline runs in container.
5. **grpc-direct RDMA ≈ raw EasyRDMA** (< 0.2% overhead). The gRPC abstraction is free at RDMA speeds.
6. **Measure jitter (p99−p50), not just mean** — jitter was the key differentiator between transports in the prior benchmark.
