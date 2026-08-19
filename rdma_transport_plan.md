# gRPC-Direct RDMA transport: project plan

Status: Phase 0 complete, all four gates passed. Phase 0.5 complete, DAQiri confirmed
local and the headline table relabelled. Measurement window committed to post-arrival.
Phase 1 complete and negative: no flag closes any part of the gap, so Phase 2 is justified
and proceeds.

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

## 5. Phase 2: minimal RDMA data path

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

## 6. Phase 3: integration into the transport

Only start this once Phase 2 passes its checks.

### Tasks

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

---

## 7. Phase 4: measurement

All arms measured on the post-arrival window fixed in section 1: completion observed
through post-FFT. This is what makes the new arm comparable to the 54 runs already
collected.

### Arms

At minimum:

- `base` (optimizations off)
- `opt` (current best: `--zc-align` and `--opt-stream`, both default-on)
- `rdma` (the new transport, PXI producing over the wire)
- `rdma-local` (the new transport, local CPU producer, same receive path)
- `daq` (DAQiri, single-process RC loopback)

`rdma-local` is the control for the cache-state question. `rdma` and `rdma-local` differ
only in who dirtied the buffer, a remote NIC DMA versus a local CPU store, so any
difference between them is that effect and nothing else. Without it, every comparison
between the new arm and the four existing local-producer arms silently assumes producer
identity does not matter, which is exactly the kind of assumption section 7c of the
handoff was built on retracting. If the two agree, say so and the assumption is earned.

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

Single interleaved run, 9 sizes, arms rotated, 3 reps minimum. Extend
`headline_sweep.sh` rather than writing a new script, since it already interleaves
correctly at each size and stamps the git SHA. Extend `headline_table.py` for the sign
tests and the residual decomposition.

### Report

- `e2e_p50` per arm per size, with the gap and gap percentage. Label the column
**post-arrival processing latency**, not end-to-end latency.
- Residual decomposition (`e2e - fft`), which is what isolates transport from transform.
- Sign tests on all paired cells.
- Delivery accounting per arm.
- Explicit statement of which path each arm used and who produced the bytes.

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
