# gRPC-Direct RDMA transport: project plan

Status: Phase 0 complete, all four gates passed. Phase 0.5 complete, DAQiri confirmed
local and the headline table relabelled. Measurement window committed to post-arrival.
Phase 1 complete and negative: no flag closes any part of the gap, so Phase 2 is justified
and proceeds. Phase 2 complete and passing: 31,800 verified messages, the broken-ordering
control fails as required, nothing on the hot path. Phase 3 scoped and the fork audited; the
scoping changed its shape twice. The RDMA transport already exists in the Rust library, so the
work is to make it land in memory we allocated; and the PXI's undocumented copy of that library
turns out to differ from upstream in exactly one source file, in five coherent changes, with
nothing hidden in the four `.bak` snapshots. Gate 5 passed: easyrdma does accept a
`cudaHostAlloc`'d pool and the bytes land in it, the GPU reads them in place, and the negative
control lands outside. The gate also found that external buffers complete by callback only and
cannot be combined with RX polling, which changes the binding work and adds a confound Phase 4
has to control for.

**Phase 3 steps 3 and 4 are done and building.** The FFI is bound and the library now has a
second server entry point, `grpc_direct_server_create_ext`, that receives directly into a
caller-allocated pool. `rdma_server_create` was left with zero deletions, so the stock arm is
still exactly the code the existing numbers came from. The whole change lives on branch
`daqiri-extbuf` of `dvthomas01/grpc-direct`, forked from `ni/grpc-direct` at `2d404a5`, with the
measured state isolated as its own commit ahead of anything we added.

**Two scope decisions were taken on 2026-08-20 against a week and a half.** Steps 5 and 6 are
swapped so the working path is built before the race demonstration, because the race is the only
unschedulable item here and an overrun should cost a section rather than the result; and the
race demonstration is timeboxed to two days with the window arithmetic written down in advance,
including the fact that at 4 MB it cannot reproduce and the arithmetic is the deliverable.
Phase 4 is reduced to three arms, two sizes and five reps, with the four dropped arms and the
cost of each loss recorded in section 7 so it reads as a decision. Next: step 5, the real path.

---

## 1. What we are building, stated precisely

An RDMA transport for gRPC-Direct in which the receive buffers are `cudaHostAlloc`'d
host memory that the GPU reads in place.

Flow: the PXIe-8881 issues an RDMA write over RoCE into a buffer on the Spark. That
buffer was allocated with `cudaHostAlloc` plus `cudaHostAllocMapped` and registered with
the NIC via `ibv_reg_mr`. The Spark polls the completion queue, then hands cuFFT the
device pointer obtained from `cudaHostGetDevicePointer` and transforms in place.

No copy at any stage. The NIC writes once, the GPU reads exactly what the NIC wrote.

### What this is not

This is not GPUDirect RDMA. GPUDirect RDMA means the NIC writing into `cudaMalloc`'d
device memory, and that is impossible on GB10. NVIDIA states that on DGX Spark's unified
memory architecture, memory from pinned device allocators cannot be coherently accessed
by the CPU complex or by PCIe peripherals, so GPUDirect RDMA is unsupported and
nvidia-peermem, dma-buf, and GDRCopy do not work. Our own `devwrite` harness arm
confirmed the CPU side of the same wall by faulting on a store into `cudaMalloc`'d
memory. There is no flag, module, or firmware change that lifts this. The chip has no
separate GPU memory for a NIC to target.

Reference: `docs.nvidia.com/dgx/dgx-spark-porting-guide/porting/cuda.html`, and NVIDIA
forum post 348787 reply 6 (MackenzieNVIDIA, October 2025).

### Why we expect it to help

Measured, 4 MB, 15 reps, rotated arm order: `cudaHostAlloc` transforms in 53.22 µs
against `cudaHostRegister`-on-`/dev/shm` at 64.19 µs. That is 10.94 µs of GPU time,
shmreg losing 15/15 cells at p = 6.1e-05. It is larger than the entire remaining 8.10 µs
gap to DAQiri.

Today iceoryx2 allocates our buffers with `shm_open` and we register them after the
fact. Owning the allocation is the point of this project.

### The measurement window: post-arrival, committed

The clock starts when the receiver observes the buffer and stops after the FFT
completes. Wire time is outside the window.

This is not a new convention, it is the one both existing arms already use.
`bench_daqiri_roce_pipeline.cc` documents `e2e_latency_us` as "received-buffer-in-hand
-> post-FFT (RX-side wall clock)" and takes `t_rx` after the RECEIVE completion is
dequeued; `bench_grpc_server.cc` takes `t_recv` on handler entry, after the message has
landed. Neither has ever included time in flight.

Three reasons to commit to it rather than widen it:

- It keeps all 54 existing runs comparable. Widening the window would orphan them.
- It avoids cross-box clock synchronisation entirely. A networked end-to-end figure needs
sender-side timestamps on the PXI comparable to receiver-side timestamps on the Spark,
which is a materially larger job than the transport itself.
- It is where the mechanism under investigation lives. The 10.94 µs allocator penalty at
4 MB is paid after the bytes land, and so is every microsecond of the remaining 8.10 µs gap.

**Therefore the 8.10 µs gap is a post-arrival processing figure**, for both arms, and
always was. It does not describe networked end-to-end latency and never did. Label it
that way everywhere it appears.

Networked end-to-end latency is a different question and is out of scope. See section 7
for what measuring it would take.

### Framing for the writeup

This is DAQiri's architecture. DAQiri already does RoCE into `cudaMallocHost` buffers.
We are not inventing a faster path, we are giving gRPC-Direct the same one. The claim is
"DAQiri-class performance without giving up the gRPC API," which was the original project
goal. Do not frame this as beating DAQiri; parity is the expected and sufficient outcome.

---

## 2. Standing rules

These apply to every phase. They exist because this project has already produced four
measurement artifacts, each a different failure mode.

**Measurement discipline**

- Arms interleaved within a rep, never all of one arm then all of another.
- Minimum 3 reps, 5 preferred. One interleaved rep removes bias between arms but gives
no estimate of how much a single measurement moves. That is what produced the
retracted 2.91 µs figure.
- Rotate the starting arm each rep. A fixed order confounds position with arm identity.
- Paired sign test reported alongside every delta.
- Spectrum verified (top-3 peaks) at 16, 256, and 4096 KB before any timing is believed.
- Git SHA stamped into every CSV row. Rebuild on the Spark before measuring.
- Never compare numbers across runs. Clocks cannot be locked on this box and drift of
9 µs has been observed.
- Any buffer under test must be written to before it is transformed. The read-only
memory-kind ladder produced a false null that stood for weeks.

**Artifacts already burned, do not repeat**

1. Async timers measure the enqueue, not the work. Cost surfaces at the sync point.
2. Thermal drift across runs. Never compare across runs.
3. Single-rep variance inside a properly interleaved run.
4. Read-only measurement of a path that is written to in production.

**Suspicion rule**

Any suspiciously large win gets its output verified before it is reported. A prior
53.9 µs "win" came from kernels that never launched because `CMAKE_CUDA_ARCHITECTURES`
was pinned to 90 on an sm_121 part, and cuFFT hid it via fat binaries.

**Environment**

- The PXI address `192.168.20.2/24` on `enp117s0` is non-persistent and disappears on
reboot, and so is the MTU. Both lines must be re-run as root on the PXI after any
reboot: `ip addr add 192.168.20.2/24 dev enp117s0` and `ip link set dev enp117s0 mtu
9000`. The MTU one is not optional. The PXI comes up at 1500, giving a RoCE `active_mtu`
of 1024 against the Spark's 4096, and a queue pair silently negotiates the minimum with
no error. Measured cost of the mismatch at 4 MB: 730.29 µs and 5518 MiB/s at 1024
against 694.76 µs and 5843 MiB/s at 4096, with the 2-byte message unmoved as the
control. Confirm with `ibv_devinfo` on both ends rather than assuming the change took.
- `perftest` is built from source at `/home/admin/perftest` on the PXI, nothing installed
system-wide. It needs libpci, which the box lacks, so `pciutils` is built first into
`/home/admin/pciutils-inst`. Do not stub the libpci call out: it detects PCIe relaxed
ordering, which affects the RDMA write performance being measured. Never touch the
package manager on a shared instrument controller.
- `10.198.65.118` is the PXI, not the Spark. `10.198.65.105` is `spark-b750`, a different
DGX Spark. Neither is ours. Only the host key fingerprint distinguishes them.
- Never use `spark-b750` as a substitute box. Different physical unit, so no number from
it is comparable to anything already collected.

---

## 3. Phase 0.5: what we are actually comparing against — RESOLVED

Run 2026-08-19, before any transport code. Answer: **the DAQiri arm is local.** The
consequence is smaller than feared, but the labelling correction is real.

### Finding 1: the DAQiri arm never crossed the cable

The `daq` arm in `scripts/headline_sweep.sh` runs `bench_daqiri_roce_pipeline` against
`daqiri/config_roce_pipeline.yaml`. That source hardcodes both endpoints to the same
address:

```cpp
static const std::string  SERVER_ADDR = "192.168.20.1";
static const std::string  CLIENT_ADDR = "192.168.20.1";
```

`192.168.20.1` is the Spark's own RoCE IP. One process, TX thread and RX thread,
same-device RC loopback through `rocep1s0f0`. The config header states it outright:
"Single-process, single-device RC loopback on the one already-assigned RoCE IP." The PXI
is not involved.

### Finding 2: the arithmetic agrees, twice over

At 50 Gb/s, wire time is `bytes / 6250` µs. Against the headline DAQiri e2e p50:

| KB | theoretical wire | DAQiri e2e p50 | verdict |
|---|---|---|---|
| 16 | 2.62 | 11.70 | inconclusive |
| 64 | 10.49 | 15.56 | inconclusive |
| 128 | 20.97 | 22.16 | impossible: leaves 1.19 µs for a 17.27 µs FFT |
| 256 | 41.94 | 20.74 | **below wire time** |
| 1024 | 167.77 | 28.27 | **below wire time** |
| 4096 | 671.09 | 62.31 | **below, by 10.8x** |

Gate 3 closes it independently and by measurement rather than arithmetic: a real
PXI-to-Spark 4 MB RDMA write took **694.76 µs**, against DAQiri's reported 62.31.

### Finding 3: the gap survives, the label does not

The original worry was that an RDMA transport would run over the wire while its baseline
never did. That is not the failure, because **neither arm's window includes wire time.**
Both clocks start after arrival, on the receiver, as set out in section 1. The two arms
are therefore comparable to each other as they stand, since both producers are local.

What is wrong is the label. The headline table reads as end-to-end networked latency and
is nothing of the kind. It is post-arrival processing latency, which is the honest and
still useful thing it always measured.

### Consequences

- The 8.10 µs gap stands. No number changes.
- Every place it is quoted gets relabelled post-arrival processing latency, and the
DAQiri arm gets identified as single-process RC loopback. Done in `handoff.md` section 5.
- The RDMA arm keeps the same window, so it lands directly comparable to all 54 existing
runs without re-running anything.
- `daq-wire` is not needed. It stays named and out of scope in section 7 rather than
deleted, so the next reader knows it was decided and not overlooked.
- One new confound falls out of this and is carried into section 9: a buffer dirtied by a
remote NIC DMA may not be in the same cache state as one dirtied by a local loopback DMA
or a local CPU store. Given that the mechanism under investigation is itself a
page-and-cache-attribute effect, that cannot be assumed away. Section 7 answers it with a
control arm.

---

## 4. Phase 1: the allocator flag experiment — RESOLVED, NEGATIVE

**This may make the entire RDMA project unnecessary. Do it first.**

It did not. Ran 2026-08-19, `data/memsrc_flags.csv`, SHA `6070ae1`, 9 sizes x 8 arms x
5 reps x 200 iterations with arms rotated per iteration. Full writeup in `handoff.md`
section 7e. Summary:

- **The third decision rule fired.** Every `cudaHostAlloc` arm closes 94-101% of the
`shmreg`-to-`hostalloc` gap, every `cudaHostRegister` arm closes 0% within noise, at all
nine sizes. Registration versus driver allocation is irreducible, the ownership problem is
real, and Phase 2 proceeds.
- **The hypothesis below is refuted, not confirmed.** WriteCombined genuinely changes the
mapping (backed by `/dev/nvidiactl`, three extra vmflags) and changes the timing by less
than 0.5 µs at 4 MB. Cacheability as stated is not the mechanism, which remains unknown.
That is not a blocker for Phase 2, since the effect reproduces regardless of why.
- `cudaHostRegisterReadOnly` is rejected by the driver, "operation not supported". Second
confirmation of the E4 refusal.
- `--zc-bigreg` re-run under write-then-transform discipline is null again. Closed.
- The 10.94 µs figure below was 4 MB only. The ladder splits it as +14.94 µs transform and
+33.86 µs write at 4 MB, with the transform half absent below 1 MB. Only the transform half
is charged to the post-arrival window, and it alone still exceeds the 8.10 µs gap.

The original plan text follows unchanged, since the hypothesis and decision rules are what
make the result interpretable.

No RDMA involved. It runs entirely inside `bench_fft_memsrc.cc`.

### Hypothesis

The 10.94 µs advantage of `cudaHostAlloc` over `cudaHostRegister` at a 4 MB payload is a
page-attribute effect, most likely cacheability. The CUDA Tegra documentation notes that
`cudaHostAlloc`
can be allocated with `cudaHostAllocWriteCombined` or the default flag, and that
userspace mappings must match the allocation attribute or behavior is undefined. That is
an attribute set at allocation time, which registration cannot retroactively apply.

### Arms

Allocation side:

- `cudaHostAlloc` default
- `cudaHostAlloc` with `cudaHostAllocWriteCombined`
- `cudaHostAlloc` with `cudaHostAllocMapped`
- `cudaHostAlloc` with `Mapped | WriteCombined`

Registration side, all on the same `/dev/shm` buffer:

- `cudaHostRegister` `Default`
- `cudaHostRegister` `Portable`
- `cudaHostRegister` `Mapped`
- `cudaHostRegister` `ReadOnly` if the API permits combining it

Also re-run `--zc-bigreg` (page-rounded registration) under write-then-transform
discipline. It measured null previously, but that was under the read-only ladder that
has since been retracted.

### Decision rules

- If any `cudaHostRegister` variant closes most of the 10.94 µs at 4 MB: we have a one-line
fix, the ownership problem evaporates, and RDMA becomes optional rather than necessary.
Report it and re-scope.
- If `WriteCombined` differs sharply from default: we have identified the mechanism and
can state precisely why driver allocation wins. This answers the open question sent to
the teammate weeks ago.
- If nothing moves: registration versus driver allocation is irreducible, the ownership
problem is real, and Phase 2 proceeds with a stronger justification.

### Output

Table with all arms at 9 sizes, sign tests, committed CSV, and a `handoff.md` section.
Delivered: `data/memsrc_flags.csv`, `data/memsrc_flags_run.log`, `handoff.md` section 7e.

---

## 5. Phase 2: minimal RDMA data path — COMPLETE, PASSING

Built as `rdma/rdma_fft_server.cu` (Spark) and `rdma/rdma_fft_client.cc` (PXI), sharing
`rdma/rdma_contract.h`. Full writeup in `handoff.md` section 7f. Against the checks below:

- Spectral verification at **all nine sizes**, not just the three listed, because Phase 1
found the allocator penalty is size-dependent and a small-payload difference should show up
in the correctness test rather than in Phase 4. 200 messages each, 1800/1800 verified.
- **Broken ordering fails, as it must.** 59 of 60 messages wrong, reporting the 400 kHz
poison tone. The checker is sensitive to the race. One 16 KB message in twenty passed even
with the ordering broken, so the test's own sensitivity is size-dependent and needs enough
messages at the smallest payload; that is recorded in 7f.
- **30,000 messages** at 16, 256 and 4096 KB: zero verification failures, zero completion
queue errors, zero timeouts.
- **Nothing on the hot path, asserted.** 1 alloc, 1 reg_mr, 4 translate at startup and the
same at the end. Calls after startup abort at the call site; a per-message assertion catches
anything that bypassed the wrappers.

One deviation from the plan text below: raw verbs with a TCP side channel rather than
`rdma_cm`. Reason: that is the path perftest takes, and perftest is the only RDMA traffic
ever demonstrated between these two boxes, so a failure is our bug rather than an unexplored
interaction with `rdma_cm` on an NI Linux RT kernel.

The original plan text follows unchanged.

No gRPC. No iceoryx2. No protobuf. The smallest program that proves the architecture.

### Build order

**2.1 Receive pool.** On the Spark, allocate a ring of N slots sized to the largest
payload, each 4 KB aligned (required per the Tegra section of the GPUDirect docs).
Allocate with `cudaHostAlloc` plus `cudaHostAllocMapped`. Register the whole pool once
with `ibv_reg_mr` at startup. Call `cudaHostGetDevicePointer` once per slot at startup
and cache the results.

Never register, translate, or allocate on the hot path. The GPUDirect docs call pinning
expensive and prescribe lazy unpinning with a registration cache; the same reasoning
applies to `ibv_reg_mr` on host memory.

**2.2 Connection.** Standard RDMA connection manager setup, PXI as active side. Exchange
rkeys and slot addresses. Use RDMA WRITE with immediate, or WRITE plus a separate
notification, whichever produces a completion the receiver can poll.

**2.3 The transform, with correct ordering.** This is the correctness-critical step.

The CUDA GPUDirect documentation states that only CPU-initiated CUDA APIs order these
memory operations as the GPU observes them, and that a GPU kernel running concurrently
with an in-flight RDMA write into the same memory may observe stale, partial, or
out-of-order data. It is a data race.

Requirement: **the thread that observes the completion must be the thread that launches
cuFFT, and the launch must happen after the completion is observed.** Do not poll the CQ
on one thread and launch on another without explicit ordering between them.

Getting this wrong produces a plausible-looking spectrum computed on partially arrived
data. That is the same failure class as the all-zero spectrum incident, with a subtler
signature.

### Checks

- Sender writes a known pattern, for example a synthetic signal with known peaks.
Receiver verifies the top-3 spectral peaks match the expected values. Run at 16, 256,
and 4096 KB.
- Deliberately break the ordering (launch before the completion is observed) and confirm
the verification fails. If it passes anyway, the test is not actually sensitive to the
race and needs strengthening before it can be trusted.
- Run 10,000 messages and confirm zero verification failures and zero completion-queue
errors.
- Confirm no allocation, registration, or pointer translation occurs after startup.
Instrument or assert on this.

### Stop condition

If spectral verification cannot be made to pass reliably, stop and diagnose before
proceeding. Do not integrate a data path that is not provably correct.

---

## 6. Phase 3: integration into the transport — IN PROGRESS, GATE 5 PASSED

Scoping pass done 2026-08-20 by reading the actual sources rather than the headers. It changed
the shape of the phase, so the findings come first and the original task list is kept below.

Every line number below refers to the copies on the PXI: `/home/admin/grpc-direct/src/lib.rs`
and `/home/admin/easyrdma/core/api/easyrdma.h`. Those are the vendor's files and are
deliberately **not** committed here; `scripts/phase3_scope_probe.sh` re-runs the read.

**Unblocked 2026-08-20.** The Spark was off the network for part of the day and is back at the
same address; the ARP lesson from that outage is kept in `LONGTERM_CONTEXT.md`, "Settling
whether the Spark is alive". Both machines are reachable and the RoCE fabric is up end to end.

### 6.1 The premise of task 1 is wrong: the RDMA transport already exists

Task 1 below says the implementation "currently returns NULL". That came from the header
comment, and the header comment is stale. Read from `/home/admin/grpc-direct/src/lib.rs` on the
PXI (the Spark's copy could not be checked, see below):

| what | where |
|---|---|
| easyrdma FFI block, 12 functions | `src/lib.rs:270-378` |
| `RdmaServerBackend`, `RdmaClientBackend` | `src/lib.rs:599`, `src/lib.rs:644` |
| live dispatch, server and client | `src/lib.rs:1296`, `src/lib.rs:1891` |
| the stale "not yet implemented, returns NULL" comment | `src/lib.rs:1215` |

So Phase 3 is not "write an RDMA transport". It is **"make the RDMA transport that exists land
its bytes in memory we allocated"**. That is a much smaller change and, more usefully, it means
there is a working stock implementation to A/B against. Phase 4 should gain an `rdma-stock` arm
for exactly that reason: it separates "RDMA helps" from "controlling the allocation helps",
which are the two claims this project keeps conflating.

### 6.2 Why the stock implementation is not sufficient

`easyrdma_ConfigureBuffers(session, maxTransactionSize, maxConcurrentTransactions)` makes
**easyrdma** allocate and register the landing buffer. It is called at `src/lib.rs:724`, `832`
and `946`. `grpc_direct_server_receive` then hands the caller `region.buffer` directly
(`src/lib.rs:1497-1516`), and the easyrdma header describes that field as "Pointer to
internally-allocated buffer".

That is a buffer we did not allocate, which is the precise arrangement Phase 1 measured at
+48.7 µs of total time at 4 MB and Phase 2 was built to escape. Adopting the stock transport
unchanged would move the data over RDMA and still pay the penalty that motivated the RDMA work.

Two smaller corrections found while reading, both worth writing down because the documentation
is wrong about them:

- `docs/RDMA_TRANSPORT.md` says received regions are "copied into a thread-local buffer and
  immediately released". **The code does not do that.** It hands out the region pointer and
  holds the region. Doc and source disagree; the source wins, and the receive path is already
  zero-copy.
- The region is released at the *top of the next* `grpc_direct_server_receive`
  (`src/lib.rs:1487`), not at the end of the current one. So a message's buffer stays valid
  exactly until you ask for the next message.

### 6.3 The seam: `easyrdma_ConfigureExternalBuffer`

`easyrdma.h` exposes a caller-allocated path alongside the internal one:

```c
int32_t easyrdma_ConfigureExternalBuffer(easyrdma_Session session, void* externalBuffer,
                                         size_t bufferSize, size_t maxConcurrentTransactions);
int32_t easyrdma_QueueExternalBufferRegion(easyrdma_Session session, void* pointerWithinBuffer,
                                           size_t size,
                                           easyrdma_BufferCompletionCallbackData* callbackData,
                                           int32_t timeoutMs);
int32_t easyrdma_ReleaseUserBufferRegionToIdle(easyrdma_Session session,
                                               easyrdma_InternalBufferRegion* bufferRegion);
```

plus `easyrdma_Property_UserBuffers` and
`easyrdma_CloseFlags_DeferWhileUserBuffersOutstanding`, which exist specifically because
caller-owned buffers can still be in use at teardown.

This is the whole integration in one sentence: **allocate the pool with `cudaHostAlloc`, hand
it to `ConfigureExternalBuffer`, and the landing zone is ours.** None of these three functions
is currently bound in the Rust FFI block; adding them is the bulk of the diff.

**Corrected by Gate 5:** two of those three, not three. `ReleaseUserBufferRegionToIdle` is not
part of the external-buffer receive path at all, and `AcquireReceivedRegion` cannot be used
with it either. See the Gate 5 result in §6.4.

### 6.4 Gate 5, before any Rust is written

Phase 2's lesson was that a check is worth nothing until it has been watched to fail, and
Phase 0's was that a decisive feasibility question gets its own small program. The same applies
here, because the entire plan rests on an untested assumption.

**Gate 5: does `easyrdma_ConfigureExternalBuffer` accept a `cudaHostAlloc`'d pointer, and does
data actually land in it?** A C++ program on the Spark, no Rust, no gRPC:

1. `cudaHostAlloc` a pool, `cudaHostGetDevicePointer` it once.
2. `easyrdma_ConfigureExternalBuffer` over the pool. Record the return code.
3. Have the PXI send into it, then check the bytes are in *our* pool at the offset we expect,
   not in a copy.
4. **Control, and it is the point of the gate:** run the same program with
   `ConfigureBuffers` and confirm `region.buffer` is *not* inside our pool. A gate that only
   shows the new path working cannot distinguish "external buffers work" from "we misread
   which pointer we were looking at".

Gate 4 already proved raw `ibv_reg_mr` accepts a `cudaHostAlloc`'d pointer, so the odds are
good. But easyrdma is not raw verbs: it may `mmap`, re-align, or require its own page
properties. Assuming it works and finding out during the Rust integration would mean debugging
two unknowns at once.

**Abort condition.** If Gate 5 fails, the external-buffer route is closed, and the honest
options are: land in easyrdma's buffer and pay the penalty, keep the Phase 2 raw-verbs path as
a separate non-gRPC arm, or fork easyrdma too. Pick one deliberately and record why. Do not
silently fall back.

#### Gate 5 result — PASS, 2026-08-20

`scripts/gate5_extbuf.cu`, built and run on the Spark. It does not need the PXI: sender and
receiver are two sessions in one process over 192.168.20.1, so the transfer still crosses the
HCA. 17 checks, 0 failures, and three reps at different sizes and offsets
(`scripts/gate5_reps.sh`, output `data/gate5_reps.txt`), including a deliberately unaligned
offset of 1048577, all pass. Full output at `data/gate5_extbuf.txt`.

**The premise holds.** `easyrdma_ConfigureExternalBuffer` returned 0 for a 64 MiB
`cudaHostAlloc` pool, the payload landed at exactly the offset we chose, the rest of the pool
kept its `0xAB` fill, and a GPU kernel summing through `pool.dev + offset` matched the CPU sum
byte for byte. Host VA equalled device VA, as expected on GB10's coherent C2C. A second
message into a different slot did not disturb the first, so slots are independently
addressable, which is what a slot-per-message pool needs.

The control did its job: with plain `ConfigureBuffers` the region came back at
`0xabfb1f9a8040`, outside the pool's `0x32ee00000..0x332e00000`, the pool was untouched, and
the data still arrived, so the control is live rather than passing by failing to transfer.

**Three things the gate taught that the plan did not know, all of which change the work:**

1. **Completion for an external buffer arrives only by callback.** The first run failed here.
   `easyrdma_AcquireReceivedRegion` returns `InvalidOperation` (-734004) from
   `RdmaBufferQueue.cpp:105`, which throws unconditionally when `putBackToIdleOnCompletion`
   is set, and it is set for single-buffer external queues. There is no completed-buffer queue
   to block on. The receive path must pass an `easyrdma_BufferCompletionCallbackData` to
   `QueueExternalBufferRegion` and be driven from that callback. This is a different shape
   from the stock path's blocking `AcquireReceivedRegion` and it is the main structural
   difference the Rust binding has to absorb.
2. **There is no release call to make.** Because the buffer goes straight back to idle on
   completion, `easyrdma_ReleaseUserBufferRegionToIdle` is not part of this path;
   `easyrdma_Property_UserBuffers` reads 0 immediately after the callback fires. Re-arming a
   slot is `QueueExternalBufferRegion` and nothing else. This answers §6.6(b) below.
3. **Teardown needs `DeferWhileUserBuffersOutstanding`.** Run 1 printed its verdict and then
   died with `double free or corruption (fasttop)`. Closing with the defer flag removed it.
   The flag is not optional politeness; without it, closing a session that still has one of
   our regions queued corrupts the heap.

**And one constraint that reaches into Phase 4: polling and external buffers are mutually
exclusive.** `RdmaConnectedSessionBase.cpp:153` throws `OperationNotSupported` when
`usePolling` is set, and the gate confirmed it empirically at -734026. That matters twice
over. It is a real design limit: the external-buffer arm cannot use RX polling, so it pays an
interrupt wakeup on every message that a polling arm does not. And it is the only prediction in
this phase that was made from source reading *before* being run, so it is the evidence that the
rest of the source reading in §6.5 and here can be trusted.

**Consequence for the arms, to be settled before any number is quoted.** `rdma` (external
buffers) cannot poll; `rdma-stock` can, and the fork's polling fix means it actually will. A
straight `rdma` vs `rdma-stock` comparison would then differ in two things at once, allocation
ownership and wakeup mechanism, and the wakeup difference could easily be the larger of the
two. Add an `rdma-stock-nopoll` arm so the pair that differs only in who allocated the buffer
exists. If that turns out to be too many arms, the fallback is to run `rdma-stock` with polling
off and say so in the column header, but the polling state of every RDMA arm must be reported
next to its latency either way.

### 6.5 What the fork looks like — DONE 2026-08-20, and it is clean

The PXI copy at `/home/admin/grpc-direct` has no `.git`, so provenance had to be established by
content rather than by history. Upstream is `https://github.com/ni/grpc-direct.git`, named in
its own `README.md:201`. Method: hash every non-`target`, non-`.github` file on the PXI, hash a
fresh upstream clone the same way, compare. Reproduce with
`scripts/diff_grpc_direct_upstream.ps1`.

**A warning about the method before the result.** The first run reported 123 of 127 files
modified, which is not a finding, it is `core.autocrlf` checking the clone out with CRLF on
Windows against the PXI's LF. Clone with `git -c core.autocrlf=false -c core.eol=lf clone` and
the count drops to 2. A comparison that says almost everything changed is describing itself.

**Base commit: upstream HEAD `2d404a5`, 2026-06-11.** Upstream has had no commits since. The
PXI's untouched files are stamped Jun 11 15:00 UTC against that commit's 14:50 UTC, and 125 of
127 tracked files hash identically, so the base is established by content and not by timestamp.

| | count | what |
|---|---|---|
| identical | 125 | |
| modified | 2 | `src/lib.rs`, `python/pyproject.toml` |
| PXI-only | 19 | `Cargo.lock`, two `examples/*.rs` benches, and `python/grpc_direct/**` plus `*.egg-info` |
| upstream-only | 6 | `python/*.py` at the old flat path |

The whole python column is one `pip install -e .`: the modules moved from `python/` to
`python/grpc_direct/`, `pyproject.toml` changed to match, and egg-info, `__pycache__` and a
built `libgrpc_direct.so` landed beside them. Build residue, not a source edit.

**So there is exactly one modified source file, `src/lib.rs`, +529/-31.** The full diff is
vendor code, so it is **not** committed here; it sits at `data/lib_rs_vs_upstream.diff` locally
and the two scripts above regenerate it. It is five coherent changes, not a mess:

| change | where (fork line numbers) | category |
|---|---|---|
| `ERROR_DISCONNECTED = -734017` constant added to `mod easyrdma` | 286 | new constant |
| `stream_region` and `polling` fields on `RdmaServerBackend` | 609 | supports the two below |
| `rdma_server_reaccept()`, new, 69 lines | 672 | new functionality |
| RX-polling property moved **before** `ConfigureBuffers`, return code now checked | 808, 924 | **upstream bug fix** |
| `GRPC_DIRECT_RDMA_LOCAL` env var to override the client's local bind address | 865 | needed for cross-machine |
| `AcquireReceivedRegion` wrapped in a re-accept retry loop | 1490 | **datapath semantic change** |
| `rdma_reserved` field + `response_reserve` / `response_commit` | 1074, 2400 | new, saves one memcpy |
| pipelined streaming API, 6 more `extern "C"` functions | 2509-2747 | new functionality |

Four things worth carrying forward:

1. **The RX-polling fix is real and belongs upstream.** Upstream sets
   `PROPERTY_USE_RX_POLLING` *after* `ConfigureBuffers` and ignores the return code; easyrdma
   rejects it at that point with `AlreadyConfigured`, so upstream's polling flag silently does
   nothing. The fork sets it first and checks. Any `rdma-stock` arm built from unmodified
   upstream is therefore **not** polling even if asked to, which would be a confound in Phase 4.
   Build the `rdma-stock` arm from the fork with our changes disabled, not from upstream.
2. **The re-accept loop changes disconnect semantics.** Upstream returns an error; the fork
   tears the session down and blocks in `easyrdma_Accept` with `TIMEOUT_INFINITE` until a new
   client arrives. During a benchmark a peer dropping out becomes an indefinite stall in the
   receive path rather than a visible error. Phase 4 must record delivered counts anyway, which
   is what would catch this.
3. **No external-buffer API is called anywhere.** Neither `easyrdma_ConfigureExternalBuffer`,
   `easyrdma_QueueExternalBufferRegion`, `easyrdma_ReleaseUserBufferRegionToIdle`,
   `easyrdma_Property_UserBuffers` nor `easyrdma_CloseFlags_DeferWhileUserBuffersOutstanding`
   appears in upstream, in the fork, or in any `.bak`. §6.3's seam is genuinely unbound. It has
   to be added, not switched on.
4. **One suspected buffer leak, found in passing.** In `grpc_direct_client_stream_go`, if
   `easyrdma_QueueBufferRegion` fails the acquired region returns `-1` without being released,
   which loses a slot from a pool of `RDMA_MAX_CONCURRENT = 4`. Not on the Phase 3 path, not
   fixed, recorded here so it is not rediscovered as a mystery hang.

**The four `.bak` files were hiding nothing.** `scripts/audit_libr_baks.sh` diffs them in
sequence: 85714 → 86943 → 90234 → 95015 → 104008 bytes over 2026-06-22/23, adding 42, 86, 118
and 255 lines with 19, 6, 0 and 0 removed. Every function name defined in every snapshot
survives into the current file, so nothing was tried and quietly reverted. The only removals are
the RX-polling lines being moved. They are incremental saves, not abandoned variants.

**Still open:** the Spark's copy at `/home/nitest/grpc-direct` has not been compared. Run the
same hash comparison against it before building there.

**Closed 2026-08-20, and it was worth doing: the two machines are not running the same code.**
`scripts/hash_grpc_direct.sh` on the Spark, then
`scripts/diff_grpc_direct_spark_vs_pxi.ps1`. Two things came out of it.

*First, the Spark's copy has a `.git`.* The PXI's does not, which is why that audit had to
reconstruct provenance from hashes. The Spark's clone confirms the reconstruction
independently: HEAD is `2d404a5`, on `main`, tracking `origin/main`, with nothing local
committed. Every fork change is an uncommitted working-tree edit. So the base commit conclusion
in this section was arrived at by two methods that agree.

*Second, and this is the finding:* 144 files identical, **2 different**, 8 Spark-only. `src/lib.rs`
is byte-identical across both machines (md5 `b61b26dae6ecfbf0bfae2103881f45ab`), so the Rust is
the same. But the Spark carries two edits the PXI does not, and the PXI audit recorded both
files as untouched:

| file | size | what |
|---|---|---|
| `cpp/client_interceptor.cc` | +16/-5 | server-streaming end-of-stream handling |
| `plugin/cmd/protoc-gen-grpc-direct/gen_cpp.go` | 2 lines | `_actual` → `_response` in the generated move ctor and move assignment |

The plugin change is a compile fix: upstream's generator emits a `_actual` member in
`Direct<Msg>`'s move operations that does not exist, so upstream's generated C++ does not
build. The interceptor change adds a `firstRecv_` flag distinct from `isFirstMessage_` and
calls `methods->FailHijackedRecvMessage()` on the two end-of-stream paths, with an early exit
when the stream already ended. Upstream sets neither, so a hijacked server-streaming `Read()`
would not terminate cleanly. Both look like genuine fixes rather than experiments, and the
`client_interceptor.cc.bak` → `.bak_stream` → current chain shows the usual pattern: add
`[DBG ...]` prints, find it, remove the prints. Nothing hidden.

**Consequence, and it is the same lesson as the PXI audit one level down.** We link
`libgrpc_direct_cpp.a` out of `GD_BUILD`, so `cpp/client_interceptor.cc` is in every gRPC
number this project has produced on the Spark. That file is *not* the file that was audited.
The audit was run against the PXI because that is where the copy without a `.git` was, and the
machine we actually benchmark on turned out to be the one with extra uncommitted edits. Before
any Phase 4 arm is built: the fork must be created from the **Spark's** tree, not the PXI's, or
from the union of both with the difference made explicit.

One more Spark-only file worth naming: `.cargo/config.toml`, which pins
`linker = "x86_64-linux-gnu-gcc"` for `x86_64-unknown-linux-gnu`. Inert when building natively
on the aarch64 Spark; it matters the moment anything is cross-built for the PXI.

- **Build knobs are already documented** by the vendor: Cargo feature `rdma = []` with
  `EASYRDMA_LIB_DIR` and `EASYRDMA_INC_DIR`, or CMake `-DGRPC_DIRECT_ENABLE_RDMA=ON`, which
  fetches and builds easyrdma itself. `LONGTERM_CONTEXT.md` records that grpc-direct was once
  already rebuilt with `--features rdma` on both machines, so this has been done before.
- **Substituting the fork is a one-line change on our side.** `grpc_direct/CMakeLists.txt`
  takes `GD_SRC` and `GD_BUILD` as cache paths and links `-lgrpc_direct` from
  `${GD_BUILD}/cargo-target/release` with a matching `BUILD_RPATH`. Point those at the fork and
  nothing else in our tree moves.
- **Fork from upstream `2d404a5`, then replay the PXI's `lib.rs` as one commit.** That way the
  local changes have a history for the first time and our Phase 3 work sits on top of them as a
  separate commit, so the two can be told apart later.
- **Keep the diff small on purpose.** `src/lib.rs` is a single 104 KB file, so every line we
  touch is a line that conflicts on the next vendor update. Target: bind three FFI functions,
  add a pool type, and change the `ConfigureBuffers` call sites behind a flag.

### 6.6 The three ownership questions

Phase 2 was lockstep with one message in flight, which sidestepped all three. They were
deferred, not solved.

**(a) Who owns a slot between arrival and FFT completion?**

Today: easyrdma owns it, we borrow, and the borrow ends at the top of the next
`server_receive`. This has never caused a problem, and the reason is worth being precise
about, because it is luck rather than design: `s.fft->execute()` in
`grpc_direct/bench_grpc_server.cc` is **synchronous**, it synchronizes internally, which is how
`last_exec_us()` can report a time. The FFT is therefore always finished before the handler
returns, which is always before the release. The invariant holds by side effect.

That breaks the moment the FFT becomes asynchronous, which is the obvious next optimization.
Release-at-next-receive would then hand a buffer back to the NIC while the GPU is still reading
it. **This is the mirror image of the Phase 2 bug**: Phase 2 was launch-before-arrival, this is
release-before-completion. Same class, opposite end.

The decision: bind slot lifetime to a CUDA event, not to a call. Record an event after the FFT;
a slot returns to the pool only once that event has completed. And, following Phase 2's rule,
**write the failing version first**: release the slot immediately after launch, let a
subsequent message overwrite it, and confirm the spectral check fails. If it passes, the check
cannot see this race and everything built on it is unverified.

**(b) How does the sender learn a slot was freed?**

Stock behaviour is implicit and it already works: re-queueing a receive region is what makes it
eligible again, so the receive-request availability on the RC queue pair *is* the credit. The
sender blocks in `AcquireSendRegion` when all `RDMA_MAX_CONCURRENT = 4` buffers are occupied.
There is no application-level credit and none is needed.

Do **not** carry Phase 2's explicit TCP credit forward. It exists because Phase 2 bypassed
easyrdma and had to invent flow control; here the library provides it.

Open: with external buffers, confirm whether `ReleaseUserBufferRegionToIdle` alone re-arms a
slot or whether it must be paired with `QueueExternalBufferRegion`. This is a source-reading
job in `easyrdma/core/linux` and `core/common/RdmaBufferQueue.h`, not a guess.

**Answered by Gate 5: neither. There is no release step.** External buffer queues run with
`putBackToIdleOnCompletion` set, so the slot returns to idle the moment the completion callback
fires, and `easyrdma_Property_UserBuffers` reads 0 straight after. `QueueExternalBufferRegion`
is the only re-arming call, and it is also what releases credit to the sender, since
`ConfigureExternalBuffer` does not set `autoQueueRx` and therefore never posts receives on our
behalf the way `ConfigureBuffers` does.

That makes ownership *simpler* than the stock path, not harder, and it is worth being explicit
about why: the memory is ours the entire time. easyrdma never hands us a pointer and never
takes one back. What (a) above calls "release-before-completion" becomes
**re-queue-before-completion**, entirely on our side of the line, which means the CUDA-event
rule in (a) is the whole of the answer rather than half of it.

**(c) What happens when the sender outruns the receiver?**

Stock RDMA blocks: the vendor's own troubleshooting table lists "AcquireSendRegion failed — all
send buffers occupied". Stock shmem silently drops, which is the known 171-to-200-of-200
shortfall.

**That difference will contaminate Phase 4 if it is left implicit.** Under the same offered
load, a blocking arm and a dropping arm do different amounts of work, and their latency
distributions are not comparable. The right response is to measure it, not to quietly equalize
it: record delivered counts per arm and time spent blocked in send, and report both next to the
latency. The sequence accounting from `b8c0b96` covers the first half already.

### 6.7 Order of work

1. ~~Get a real upstream clone and diff it against the PXI tree. Find out what the `.bak` files
   were hiding.~~ **DONE 2026-08-20.** One modified source file, five coherent changes, nothing
   hidden in the `.bak` snapshots. See §6.5.
2. ~~Write and run Gate 5, with its negative control.~~ **DONE 2026-08-20, PASS.** 17 checks,
   3 reps, control live. See §6.4. Three protocol corrections came out of it and one Phase 4
   constraint.
3. ~~Bind the external-buffer functions in the Rust FFI block. **Two, not three:**
   `ConfigureExternalBuffer` and `QueueExternalBufferRegion`, plus the
   `easyrdma_BufferCompletionCallbackData` struct and its function-pointer typedef.
   `ReleaseUserBufferRegionToIdle` is not on this path.~~ **DONE 2026-08-20.** Applied by
   `scripts/bind_extbuf_ffi.py` (idempotent, anchored, fails loudly if an anchor is not unique)
   via `scripts/apply_extbuf_ffi.sh`. `src/lib.rs` 2871 → 2942 lines, md5
   `b61b26d…` → `cbf91c7…`, backup at `src/lib.rs.bak5`. Also bound: `PROPERTY_USER_BUFFERS`
   (0x102), `CLOSE_DEFER_WHILE_USER_BUFFERS_OUTSTANDING` (0x01), and the three error codes Gate 5
   turned up. `cargo build --release --features rdma` exits 0 with
   `EASYRDMA_LIB_DIR=$HOME/easyrdma/core/build`; the only new warnings are dead-code, which is
   correct until step 4 wires the call sites. `Option<BufferCompletionCallback>` is
   null-pointer-optimised, so `BufferCompletionCallbackData` matches the C layout exactly.
4. ~~Add the `cudaHostAlloc` pool and switch the call sites behind a build flag, keeping stock
   `ConfigureBuffers` reachable so `rdma-stock` stays measurable.~~ **DONE 2026-08-20.** Applied
   by `scripts/bind_extbuf_server.py` (seven anchors, each required to be unique) via
   `scripts/apply_extbuf_server.sh`. `src/lib.rs` 2942 → 3476 lines. Fork commit `f0f5341` on
   `daqiri-extbuf`.

   **Not a build flag in the end, and that is a better answer.** A flag would have made the
   stock arm a compile-time variant of code we edited. Instead `rdma_server_create` is left with
   zero deletions and one added field initialiser, and the external path is a second function,
   `rdma_server_create_ext`. The cost is about ninety duplicated lines of listener and accept
   handling. The benefit is that no `rdma-stock-nopoll` measurement can be attributed to
   something we introduced. New C ABI: `grpc_direct_server_create_ext`,
   `grpc_direct_server_receive_ext`, `grpc_direct_server_slot_requeue`, all three confirmed in
   `nm -D`.

   `rdma_server_reaccept` **is** modified, and this is the part worth remembering. It configures
   buffers a second time on reconnect, so without the branch a reconnected session silently
   reverts to driver-allocated buffers. Every transfer still succeeds; the payload just stops
   landing in our pool. No throughput or latency number would show it.

   `create_ext` rejects `RdmaLowLatency`, since easyrdma will not enable RX polling on an
   externally buffered session, and `grpc_direct_server_receive` rejects an externally buffered
   server rather than inventing a lifetime for it. TX keeps stock `ConfigureBuffers`; only the
   receive side has a GPU consumer.

5. **The real path, then the checks below.** Wire `create_ext` into the benchmark server:
   allocate the pool with `cudaHostAlloc`, receive through `receive_ext`, run the FFT in place,
   record a CUDA event, synchronise it, then `slot_requeue`. Build a grpc-direct RDMA client on
   the PXI to drive it. Assert the received pointer lies inside the pool and abort if it does
   not, and assert nothing allocates, registers or translates after startup.

6. **The re-queue-before-completion failure case, failing test first, timeboxed to two days.**
   Per §6.6(b) the hazard is re-queue-before-completion rather than release-before-completion,
   because Gate 5 established there is no release call: the slot returns to idle when its
   callback fires and `QueueExternalBufferRegion` is both the re-arm and the credit. Write the
   unsafe timing first, re-queueing immediately after the FFT launch, and demonstrate corruption.
   Then gate the re-queue on the CUDA event and demonstrate it stops.

**Steps 5 and 6 were swapped on 2026-08-20, deliberately.** The race demonstration was
originally first. It is the only item in this plan whose duration is bounded by giving up rather
than by effort, and putting an unschedulable item ahead of a schedulable one means an overrun
costs the entire result. With the working path first, an overrun costs a section of the writeup.
The failing-test-first discipline is unchanged; it now applies within step 6.

**The two-day timebox on step 6, and the arithmetic behind it.** The race is only observable
when the GPU work outlasts the time for the NIC to wrap back to the same slot, which with `N`
slots is `N` further arrivals.

- **At 16 KB it should reproduce.** Gate 3 measured 5843 MiB/s and a 1.81 µs latency floor, so
  one 16 KB arrival is roughly 2.7 µs of transfer plus the floor, call it 4.5 µs. With the pool
  cut to `N = 2` the window is about 9 µs, and the measured 4096-point transform is 8.8 µs
  (`fft_p50` in `data/headline_runs.csv`). Same order, so it should be reachable, and unpacing
  the client widens it further.
- **At 4 MB it will not reproduce, and that is the finding.** One 4 MB arrival is 694.76 µs
  measured, so with `N = 2` the window is about 1.39 ms. No transform in this project is within
  two orders of magnitude of that.

So the deliverable at 4 MB is the window calculation and the statement that the race is real but
unobservable above roughly N bytes, not a forced reproduction. **Do not widen the window with
artificial GPU work to make it fire at 4 MB.** A race that only appears once you add work that
is not in the pipeline is a demonstration of the knob, not of the hazard, and it would weaken
the 16 KB result by association. If two days pass without a clean 16 KB reproduction, stop and
report the arithmetic alone.

### 6.8 Out of scope for Phase 3

- Any timing quoted from Phase 2. That harness is lockstep with one message in flight.
- Changes to the shmem and tcp paths beyond keeping them building.
- `daq-wire`, which stays out of scope for the reasons in section 7.

### Tasks (original plan text, kept because 6.1 corrects it rather than replacing it)

1. Implement `GRPC_DIRECT_TRANSPORT_RDMA` in the Rust library via easyrdma behind the
Cargo `--features rdma` flag. The enum exists; the implementation currently returns
NULL.
2. Solve buffer ownership. This is the real design work:

- Who owns a slot between completion and FFT completion?
- How does the sender learn a slot has been freed?
- What happens when the sender outruns the receiver?
3. Flow control. The existing shmem path is fire-and-forget with no flow control, which
is why only 170 to 190 of 200 messages arrive at small sizes. Decide deliberately
whether to replicate that or add credit-based flow control. Whichever is chosen,
the delivery accounting added in commit `b8c0b96` applies directly and should be
wired in from the start.
4. Keep the whole path behind a flag matching the `--zc-align` and `--opt-stream`
pattern, so the existing arms stay measurable.

### Checks

- Spectral verification still passes through the full gRPC-Direct API path.
- Sequence accounting shows contiguous windows, matching the standard established for
the shmem path.
- No regression in the existing shmem and tcp transports.
- The landing buffer is demonstrably ours: assert the received pointer lies inside the
`cudaHostAlloc`'d pool, and abort if it does not.
- Nothing allocates, registers or translates on the hot path, asserted at the call site as in
Phase 2 rather than merely intended.

---

## 7. Phase 4: measurement

All arms measured on the post-arrival window fixed in section 1: completion observed
through post-FFT. This is what makes the new arm comparable to the 54 runs already
collected.

### Arms — REDUCED 2026-08-20, and this is a decision

**Three arms, two sizes, five reps.** `daq` is added only if it comes free.

| Arm | What it is | What it answers |
|---|---|---|
| `rdma` | external buffers, our pool, event-gated re-queue | the thing being built |
| `rdma-stock-nopoll` | driver-allocated buffers, same fork, RX polling **off** | does owning the allocation matter |
| `base` | gRPC-Direct shmem, optimizations off | the standing reference every earlier number uses |
| `daq` | DAQiri, single-process RC loopback | the target, if the run fits |

Sizes 16 KB and 4 MB. Five reps. Arms rotated within each rep.

**Why reduced.** The full matrix was seven arms across nine sizes. Estimated against the
remaining Phase 3 work it came to eight and a half to eleven working days with no re-runs,
against a week and a half available, and Phase 4 cannot absorb slip because it depends on
Phase 3 finishing. Three of those days were in arms that do not answer the question this phase
asks. Reducing was chosen over compressing the reps, because a three-rep result on seven arms is
weaker than a five-rep result on three.

**What was dropped, and what each loss costs:**

- **`opt`.** Its delta against `base` is already measured across 54 runs and is not disputed.
  Cost: none, the number is quotable from existing data. It is the cheapest thing on this list
  to add back.
- **`rdma-local`.** This was the control for the cache-state question, isolating who dirtied the
  buffer. Cost: **real, and it must be stated in the writeup.** Without it, any comparison
  between `rdma` and a local-producer arm assumes producer identity does not matter, which is
  exactly the class of assumption section 7c of the handoff exists to retract. The `rdma` versus
  `rdma-stock-nopoll` comparison is unaffected, because both have the same remote producer. Only
  comparisons that cross the producer boundary carry the caveat. If anything surprising shows up
  there, add this arm back before believing it.
- **`rdma-stock` with polling on.** Our path cannot poll, so a polling stock arm confounds
  allocation ownership with wakeup mechanism. Running stock nopoll-only makes the one comparison
  this phase is for a clean one. Cost: we cannot quote stock RDMA's best case. That is a claim
  worth dropping rather than a confound worth publishing.
- **Seven of the nine sizes.** The effect is size-dependent, as Phase 2 showed and as the step 6
  window arithmetic shows again. 16 KB and 4 MB bracket the range, so the endpoints are the two
  cells that carry information about the trend. Cost: no shape between them, so state a bracket
  and not a curve.

If the reduced run lands early, the order to restore is `daq`, then `rdma-local`, then the
intermediate sizes, then `opt`, then polling stock.

**Confirmed 2026-08-21. The scope above is locked and the estimate risk in it is closed.**
`rdma-stock-nopoll` was the one arm that had never been built, so its cost was the only
unknown large enough to move the schedule. It was built and run before anything else for that
reason. It came to about an hour, not the day it could have been, and it works: 500 of 500
received and verified from the PXI, no bad frames, no bad spectra.

Three things that run turned up, which the protocol below has to account for:

- The stock arm registers the library's own receive slots with `cudaHostRegister` during an
  unmeasured warmup. That is not a workaround, it is the mechanism under test. Section 7c of
  `handoff.md` measured `cudaHostRegister` memory 10.94 µs of GPU time slower than
  `cudaHostAlloc` memory at 4 MB, 15 of 15 reps, p = 6.104e-05, **and no penalty at all below
  about 1 MB**. So the arm is predicted to tie at 16 KB and separate at 4 MB. It ties: 12.40 µs
  against 12.32 to 14.64 µs for `rdma`. **4 MB is the cell that carries the result, and neither
  RDMA arm has been run there yet.** That is the next measurement, not a Phase 4 formality.
- `--slots` is meaningless for the stock arm. The library fixes four slots and sizes them
  itself, and the run confirmed exactly four distinct regions of 20480 bytes. Any slot-count
  sweep applies to `rdma` alone.
- A 500-message RDMA run finishes in well under three seconds, and the GPU takes about three
  seconds of sustained load to leave idle clocks. So those runs never ramp, which is precisely
  what produced the 21.25 µs reading that motivated the clock gate. The Phase 4 driver has to
  push unmeasured traffic ahead of the measured section for the RDMA arms, the same way
  `headline_sweep.sh` now does for the shmem arms.

### Explicitly out of scope: `daq-wire`

A DAQiri arm running PXI-to-Spark across the cable is **not** being measured. This is a
decision, not an oversight.

- It answers a different question. Under the post-arrival window, wire time is excluded
for every arm, so a wire-crossing DAQiri arm would report roughly the same numbers as
the loopback one and add nothing.
- It is only needed to claim networked end-to-end latency, which requires widening the
window to sender-side timestamps, which requires clock synchronisation between the PXI
and the Spark to well under a microsecond to resolve a gap of this size. That is a
larger piece of work than the transport.
- Gate 3 already bounds what it would show: 694.76 µs of wire time at 4 MB, paid
identically by both sides, dwarfing every difference we are chasing and cancelling in
the comparison.

What it would take, if someone later wants it: split `bench_daqiri_roce_pipeline.cc`
into `--role server|client` with a peer address, build it for NI Linux RT on the PXI,
and establish a shared time base. Record the wire time separately rather than folding it
into e2e.

### Protocol

Single interleaved run, 2 sizes, arms rotated, 5 reps. Extend `headline_sweep.sh` rather
than writing a new script, since it already interleaves correctly at each size and stamps
the git SHA. Extend `headline_table.py` for the sign tests and the residual decomposition.
Spectrum verified in every rep, not once at the start. Buffer dirtied before each timed
transform.

**Clock gate, in the harness.** `headline_sweep.sh` samples `clocks.sm` for the duration of
each run, takes the peak, refuses to record below `MIN_SM_MHZ` (2400), and writes the observed
clock into every CSV row beside the git SHA. Rows under the threshold are written marked
`CLOCKLOW` rather than dropped, since `headline_table.py` keeps only `result==OK` and a missing
cell reads as an oversight. A warmup runs the base arm until the clock ramps before the first
measured rep, and again after any `CLOCKLOW` row. This lives in the script and not in
`LONGTERM_CONTEXT.md` because a rule in a document is followed by whoever read the document.
The RDMA arms still need the equivalent, per the run-length note under Arms.

### Report

- `e2e_p50` per arm per size, with the gap and gap percentage. Label the column
**post-arrival processing latency**, not end-to-end latency.
- Residual decomposition (`e2e - fft`), which is what isolates transport from transform.
- Sign tests on all paired cells.
- **Delivered count and blocked-send time reported as two separate columns, never combined
and never normalised away.** The arms fail differently under pressure and the difference is
the interesting part. Stock shmem is fire-and-forget with no flow control, which is why only
170 to 190 of 200 messages arrive at small sizes: it *drops*. RDMA with a finite slot pool
*blocks*, because `QueueExternalBufferRegion` is the credit and a sender with no credit waits.
A latency figure that silently excludes dropped messages flatters shmem, and one that folds
blocked time into per-message latency penalises RDMA for the same underlying back-pressure.
Quoting either alone misrepresents both. Report delivered-of-attempted per arm, and total
sender-side blocked time per arm, alongside the latency percentiles.
- Explicit statement of which path each arm used and who produced the bytes, including the
`rdma-local` caveat recorded under Arms.

### Expected outcome

Parity with DAQiri, not a win. If `rdma` substantially beats DAQiri, treat that as a
suspected artifact and verify before reporting. If it substantially loses, the likely
suspects are per-message work that should have been hoisted to startup, or a
completion-handling path that is more expensive than DAQiri's.

---

## 8. Reference material

**Primary**

- CUDA GPUDirect RDMA docs, Tegra section (4.4). Governs integrated parts. The desktop
sections do not apply to GB10.
- CUDA GPUDirect RDMA docs, section 2.7 on synchronization and memory ordering. Read
twice before writing Phase 2.3.
- DGX Spark porting guide, CUDA section. The citation that justifies this architecture.
- `bench_daqiri_roce_pipeline.cc` in this repo. A working reference implementation of the
target architecture. Read it before writing anything.

**Verbs API**

- rdma-core man pages for `ibv_reg_mr`, `ibv_post_send`, `ibv_poll_cq`.
- RDMAmojo (Dotan Barak) for practical verbs usage.

**Latency tuning, for Phase 3 onward**

- Kalia, Kaminsky, Andersen, *Design Guidelines for High Performance RDMA Systems*.
Covers inline sends, unsignaled completions, and doorbell batching. On a path chasing
single-digit microseconds these choices matter more than anything GPU-side, because
the GPU side is already settled on this hardware.

**Fabric**

- NVIDIA RoCE configuration guides for PFC and ECN. Misconfiguration shows up as latency
spikes rather than clean failures.

---

## 9. Open items carried in

- Remote-DMA cache state. Every arm measured so far had a local producer: a CPU store, a
local loopback DMA, or a shared-memory write. The `rdma` arm will have a remote NIC as
its producer, and a buffer arriving that way may not be in the same cache state as one
dirtied locally. Since the mechanism under investigation is itself a page and cache
attribute effect, this cannot be assumed away. The `rdma-local` control arm in section 7
is there to measure it. Raised by Phase 0.5.
- The `n` discrepancy in the headline sweep (gRPC arms report 184 to 190 received against
DAQiri's 250) is still open. Confirm whether it is size-dependent before the final
table is published.
- Verify both arms run identical cuFFT plans: plan type, in-place versus out-of-place,
strides, batch layout, `cufftSetWorkArea`. A mismatch would scale per byte exactly like
the observed gap.
- Teammate update: open question 1 was struck through when the memory-source ladder
collapsed, then partially revived by the gap decomposition. Send a correction.
