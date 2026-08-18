# HANDOFF — gRPC-Direct latency optimization (CURRENT, 2026-08-17)

> Paste this into a new chat to continue. It is self-contained: everything a fresh session
> needs about the goal, the system, what has been measured, and what to do next.
> The previous RoCE-era handoff is preserved at `handoff_roce_2026-08-06.md`.

---

## 0. One-line status

gRPC-Direct was 1.76x slower than DAQiri at 4 MB. We found the cause (an incorrect alignment
assumption forcing an unnecessary GPU copy on 100% of messages), fixed it, and closed most of
the gap. A dedicated CUDA stream took a little more. Five other optimization ideas were
measured and rejected, and one (the arena) is blocked by an ownership boundary we do not
control. At 4 MB we went from 1.76x slower to 1.13x slower. DAQiri is still ahead at every
size, and roughly three quarters of what remains is inside cuFFT rather than in transport.

**If you read only one more thing, read section 1.** Three of this project's headline numbers
turned out to be measurement artifacts rather than results, and all three were caught late.
The most recent was a gap figure taken from a single un-repeated run; it is retracted in
section 5.

## 1. How to measure on this box (read this before you run anything)

This section is first because it is the most transferable thing here. The individual
microseconds are specific to GB10 and to this transport. The method is not.

**The constraint.** GPU clocks on this box cannot be locked. `nvidia-smi -lgc` needs
privileges we do not have. The SM clock therefore wanders with temperature and with whatever
ran before you, and the same 4 MB FFT has been observed at 45.6 us and at 63.2 us on different
runs. Any comparison between two numbers collected minutes apart is measuring the cooling
system as much as the code.

**Three rules that follow from it.**

1. **Interleave the arms.** Never run all of arm A and then all of arm B. Run A, B, C
   adjacently at one size, then repeat the whole triple. Drift then hits all arms about
   equally and cancels in the paired differences. `scripts/headline_sweep.sh` and
   `scripts/trio_probe.sh` are both built this way; `scripts/grpc_sweep.sh` and
   `scripts/roce_sweep.sh` are not, which is exactly how the bad number below got made.
2. **Report the residual, not just end-to-end.** The residual is `e2e_p50 - fft_p50`. When
   the clock sags, e2e and the transform time sag together, so the difference between them
   stays put. DAQiri's residual is flat near 4.9 us over a 256x size range, which is what a
   real fixed floor looks like. If your residual moves when nothing structural changed, you
   are looking at thermals.
3. **Repeat and sign-test.** Three reps per cell, then count how many paired cells favour the
   new arm. When magnitudes are noisy but the ordering is stable, the sign is the part worth
   quoting. The trio's win is 0.15 to 0.39 us, far inside the run-to-run spread, but it took
   9 of 9 paired cells, and that is a defensible claim where "the median dropped 0.3 us" is
   not. `scripts/headline_table.py` does this automatically.

**Both burns, so you can recognise the shape of them.**

- *The async timer.* A stage timer wrapped around the realign copy read 3.5 to 5.2 us, so the
  copy looked cheap and got dismissed. `cudaMemcpyAsync` only enqueues. The real 77 us landed
  later, inside the FFT's `cudaEventSynchronize`, and got attributed to the FFT. **If you time
  an async CUDA call, you are timing the enqueue.** Compare wall time against GPU event time
  to find work that has been billed to the wrong stage.
- *Thermal drift.* The gap at 4 MB was reported as 12.2 us, and a memory-source ladder
  (`cudaMalloc` 45.6 / `cudaHostAlloc` 58.8 / `cudaHostRegister` 68.8) was built on top of it
  to explain where those microseconds went. Both were assembled from separate runs. A single
  interleaved run put the gap at 2.9 us and showed the two FFT times within 0.7 us of each
  other. The ladder was drift. An entire causal story had been built on it, and it was wrong.

**One more, about sample counts.** Warmup discards the first N *received* messages, not the
first N sequence numbers. An early loss burst therefore shifts the measurement window forward
instead of punching holes in it. Check sequence *contiguity*, not row count, before you
conclude anything about drops. `scripts/check_drop_bias.py` does this.

## 2. What we are trying to do

Make gRPC-Direct's end-to-end latency match or beat DAQiri's RoCE path, while:

- keeping the gRPC API structurally the same (optimize on top of it, do not replace it),
- putting every optimization behind an opt-in mode flag so the baseline stays measurable,
- proving correctness (spectral output) before trusting any speedup.

The cross-machine RoCE test from the previous arc is shelved. Do not restart it.

## 3. Where the work lives

- **Branch:** `grpc-direct-optimization`, cut from `main` at 57ba6d3. **`main` is untouched.**
- **Commits on the branch:**
  - `5eaaf89` instrument the residual + fix the alignment rule (Phase 0, E1, E2)
  - `4de101c` E3/E4 measured and rejected + fix wrong CUDA arch
  - `a35bdb6` handoff docs
- **Pushed** and tracking `origin/grpc-direct-optimization`. Git identity: Dami Thomas,
  damithomas03@gmail.com. Remote `https://github.com/dvthomas01/DAQIRI_v_GRPC.git`.
- **Note:** `PROGRESS.md`, `SHORTTERM_CONTEXT.md`, `LONGTERM_CONTEXT.md` are in `.gitignore`
  by existing repo convention. They are updated on disk but intentionally not committed.
- **Also note:** the previous RoCE session left a lot of uncommitted work in the working tree
  (RoCE pipeline sources, `data/*.csv`, `presentation/`, many `scripts/probe_*.sh`). It is
  untracked and shared across both branches. It was deliberately left alone. Do not commit it
  to the optimization branch.

## 4. How we found the problem (the reasoning that mattered)

**The key analytical move:** decompose end-to-end latency into `e2e - fft_exec`, call it the
residual, and compare across payload sizes.

| samples | size | DAQiri residual | gRPC residual |
|---|---|---|---|
| 4096 | 16 KB | 4.93 | 8.11 |
| 65536 | 256 KB | 4.99 | 12.96 |
| 262144 | 1 MB | 4.83 | 25.90 |
| 1048576 | 4 MB | 4.93 | 81.46 |

DAQiri's residual is flat at ~4.9 us across a 256x size range, which is a fixed floor (CUDA
event record + sync + clock reads). gRPC's grew with size. At 4 MB the residual gap (76.5 us)
was larger than the total e2e gap (62.6 us), so the entire problem lived in the residual.

**First hypothesis was wrong.** We suspected re-pinning the payload every message
(`cudaHostRegister` per buffer). Instrumentation killed it: `cudaHostRegister` ran **once**,
with 249 cache hits, at 0.048 us p50.

**Actual root cause.** The server gated in-place cuFFT on a hard-coded alignment test:

```cpp
const bool needs_realign = (reinterpret_cast<uintptr_t>(dptr) & 15) != 0;
```

It assumed protobuf's `RepeatedField<float>` backing store was 16-byte aligned. **It is
8-byte aligned.** So the test was true for every message and 100% of buffers took a
device-to-device realign copy into scratch. cuFFT accepts the 8-byte pointer, so that copy was
never necessary. It cost ~77 us at 4 MB.

**Why it hid.** A stage timer around the copy read only 3.5 to 5.2 us because
`cudaMemcpyAsync` merely enqueues. The real cost surfaced later inside the FFT's
`cudaEventSynchronize`. Comparing FFT wall time against FFT GPU-event time exposed it:

| size | fft wall | fft GPU event | difference | residual gap |
|---|---|---|---|---|
| 16 KB | 13.49 | 8.86 | 4.62 | 3.18 |
| 256 KB | 22.78 | 13.60 | 9.18 | 7.97 |
| 4 MB | 121.94 | 44.93 | **77.01** | **76.53** |

## 5. Current scoreboard (p50 us)

> **This section has now been wrong twice, in opposite directions. Read the retraction
> before quoting anything.**
>
> Version 1 reported a **12.2 us** gap at 4 MB plus a memory-source ladder explaining it. Both
> came from a gRPC sweep and a DAQiri sweep run back to back rather than interleaved, so the
> arms drifted apart thermally and the drift was read as a result.
>
> Version 2 reported a **2.91 us** gap at 4 MB and concluded the transform was not involved.
> That run was interleaved, which fixed the first problem, but it was a **single rep**, so
> there was no way to see how much a single measurement moves. It did not replicate. Its
> DAQiri 4 MB figure (69.07) came in 6.8 us slower than the repeated run below (62.31) while
> the gRPC figure barely moved, which inflated our apparent standing.
>
> The table below is 2 reps, arms interleaved within each rep, 54 runs, one build
> (`gitsha 952b68a` stamped on every row). Raw data in `data/headline_runs.csv`.

All three arms measured adjacently at each size, both reps in one thermal window:

| KB | base | optimized | DAQiri | speedup | gap | gap % | base res | opt res | daq res |
|---|---|---|---|---|---|---|---|---|---|
| 16 | 17.09 | **12.78** | 11.70 | 1.34x | +1.09 | 9.3% | 8.27 | 5.46 | 5.13 |
| 32 | 18.36 | **14.14** | 12.58 | 1.30x | +1.55 | 12.3% | 9.04 | 5.53 | 4.96 |
| 64 | 21.71 | **17.38** | 15.56 | 1.25x | +1.82 | 11.7% | 10.02 | 5.59 | 5.02 |
| 128 | 27.37 | **23.17** | 22.16 | 1.18x | +1.01 | 4.6% | 10.92 | 5.60 | 4.89 |
| 256 | 27.45 | **23.78** | 20.74 | 1.15x | +3.03 | 14.6% | 13.23 | 5.63 | 4.87 |
| 512 | 36.02 | **28.38** | 25.91 | 1.27x | +2.47 | 9.5% | 18.08 | 5.60 | 4.98 |
| 1024 | 47.70 | **32.87** | 28.27 | 1.45x | +4.60 | 16.3% | 26.86 | 5.73 | 4.96 |
| 2048 | 67.85 | **42.08** | 37.11 | 1.61x | +4.97 | 13.4% | 45.80 | 6.02 | 4.97 |
| 4096 | 127.02 | **70.41** | 62.31 | **1.80x** | +8.10 | 13.0% | 81.88 | 6.65 | 4.95 |

Paired sign tests over all 18 (size, rep) cells, all four at p = 7.6e-06:

- optimized beats base on residual **18/18**, and on e2e **18/18**
- DAQiri beats optimized on residual **18/18**, and on e2e **18/18**

So the alignment fix plus `--opt-stream` is a real and large win, and DAQiri is still
consistently ahead. Both statements are solid; neither is close to the noise.

**Where the remaining gap actually lives.** Because `resid = e2e - fft`, the gap decomposes
exactly, per run: `(opt_e2e - daq_e2e) = (opt_fft - daq_fft) + (opt_resid - daq_resid)`.
Differencing inside each (size, rep) cell before taking the median keeps the identity exact
and cancels drift:

| KB | e2e gap | cuFFT gap | residual gap | share in cuFFT |
|---|---|---|---|---|
| 16 | 1.09 | 0.77 | 0.32 | 71% |
| 64 | 1.82 | 1.25 | 0.57 | 68% |
| 256 | 3.03 | 2.27 | 0.77 | 75% |
| 1024 | 4.60 | 3.82 | 0.77 | 83% |
| 2048 | 4.97 | 3.92 | 1.05 | 79% |
| 4096 | 8.10 | 6.40 | 1.70 | 79% |

**This is the important result of the run, and it reverses a previous conclusion.** Version 2
of this section said the two cuFFT times were within 0.7 us and therefore "whatever is left is
not the transform." That is refuted. The same transform, same size, same GPU, same minutes,
is consistently slower in the gRPC process, and the difference **grows with buffer size**:
0.77 us at 16 KB to 6.40 us at 4 MB. Transport overhead, the part we own, is only 0.3 to 1.7 us.

A cost that scales with payload size inside cuFFT is a memory bandwidth or placement symptom,
not a launch overhead symptom. That points straight back at where the input buffer lives, which
is the ownership problem in section 7.

**Also retracted: the "1024/2048 KB anomaly" was never specific to those sizes.** Version 2
reported our cuFFT as ~4 us slower at 1024 and 2048 KB but matching at 4096. With two reps the
cuFFT gap is present at *every* size and rises monotonically. The apparent match at 4 MB was
the artifact, not the mismatch.

Throughput at 4 MB went from about 33,000 to 58,000 MB/s. Correctness verified: top-3 spectral
peaks identical to the CPU-copy ground truth at every size, to every printed digit.

**What survives from the earlier corrections.** The gRPC residual really is flat now: 5.46
rising to 6.65, against DAQiri's 4.87 to 5.13. Before the alignment fix it grew 8.11 to 81.46.
The size-dependent *transport* cost is gone. The `base` arm in the table above still shows that
old growth (8.27 to 81.88), which is a useful control confirming the fix is what moved.

## 6. Mode flags

Server: `grpc_direct/bench_grpc_server.cc`. Two flags are now defaults, each with an escape
hatch so the old behaviour stays measurable. Everything else is opt-in.

| Flag | Experiment | Verdict |
|---|---|---|
| `--stage-timing` | Phase 0 attribution, prints a residual breakdown at teardown | keep, diagnostic |
| `--zc-align` / `--no-zc-align` | **E2:** probe cuFFT at runtime instead of assuming 16 B | **DEFAULT ON.** The win, 1.67x at 4 MB |
| `--opt-stream` / `--no-opt-stream` | dedicated non-blocking stream, `cufftSetStream`, spin-poll completion | **DEFAULT ON.** 0.15 to 0.39 us of residual, 9/9 paired cells |
| `--opt-nolock` | drop the global mutex + map lookup on the hot path | kept, opt-in: inside the noise |
| `--opt-affinity N` | pin the handler thread to core N | kept, opt-in: neutral to harmful |
| `--zc-h2d` | **E1:** realign via H2D from pinned host instead of D2D | rejected: no change (76.6 vs 76.3), worse p99 |
| `--zc-kernel` | **E3:** SM grid-stride copy, then device-memory FFT | rejected: 110.8 vs 76.4 at 4 MB |
| `--zc-bigreg` | **E4:** register whole 64 KB GPU pages like DAQiri | rejected: 77.5 vs 76.4, no effect |

Why only one of the trio earned a default:

- `--opt-stream` won 9 of 9 interleaved paired residual comparisons. Small but consistent.
- `--opt-nolock` measured inside the noise, which in hindsight is obvious: the mutex is
  uncontended, so there was never anything to win. Its lock-free fast path carries a real
  session-lifetime hazard (a late redelivery could touch a freed session, hence the retirement
  logic in `FinalizeShmemSession`). Risk with no measured gain is a bad trade, so it stays off.
- `--opt-affinity` was neutral at best and hurt the 4 MB tail (p99 of 118 us). grpc-direct
  already pins its own handler thread, so forcing a core fights the runtime rather than
  helping it.

Pre-existing flags: `--port --bufsize --n-buffers --warmup --out --one-shot --transport
--zero-copy --zc-parse --verify`.

Rejection detail worth remembering:
- E1: D2D-from-mapped and H2D-from-pinned both hit the same ~52 GB/s wall. The copy engine is
  the limit, not the API choice.
- E3: the SM kernel copies at ~102 GB/s, genuinely double the copy engine, but it needs
  roughly 170 GB/s to pay for itself.
- E4: `cudaHostRegisterReadOnly` is rejected outright by the GB10 driver ("operation not
  supported"), so it was replaced by `--zc-bigreg`, which also did nothing.

## 7. Known limitation: we do not own the payload allocation

This was investigated on a timebox and closed. Do not reopen it without a change on the
grpc-direct side.

**The idea.** DAQiri allocates one `cudaHostAlloc` region at init with slots strided by
64 KB, so alignment and mapping are correct by construction. We register an arbitrary heap
block with `cudaHostRegister`. The proposal was to install a `google::protobuf::Arena` whose
initial block sits inside a pre-registered `cudaHostAlloc` region, so received messages would
land in the good kind of memory.

**Why it cannot be done from here.**

- The zero-copy pointer and size (`_zcptr_` / `_zcsz_` in
  `grpc_direct/pipeline_fft.grpc_direct.pb.h`) are populated by a patched protobuf TcParser
  handler (`ZCRawFieldHandler`, which calls `msg->_ParseZCData(ptr, len)`).
- The buffer it points at is an **iceoryx2 shared-memory loan allocated by the Rust runtime**.
  The segment is created at startup and slots rotate through a ring. It is not protobuf's
  memory and protobuf never allocated it.
- Our handler receives a `const BufferRequest*` and does not own its lifetime. There is no
  hook to supply an arena for received messages, and the public C interface (`grpc_direct.h`)
  exposes no custom-allocator seam either.
- Changing this means changing grpc-direct's Rust side, which is a separate codebase
  (`~/grpc-direct`, not in this repo) and would break the project rule that the gRPC API stays
  structurally intact.

**Why it is now the leading hypothesis again.** This paragraph previously said the arena had
"stopped being worth much," on the grounds that our cuFFT and DAQiri's were within 0.7 us so
payload placement had under a microsecond of headroom. That was based on the single-rep run and
is withdrawn. The 2-rep sweep in section 5 shows the cuFFT gap is real, present at every size,
and growing with payload: 0.77 us at 16 KB to 6.40 us at 4 MB, which is 79% of the total gap
there. A per-byte cost inside the transform is what you would expect if the input buffer sits
in memory the transform reads less efficiently. That is exactly what this section is about.

**Status: blocked, but now the highest-value blocked item.** The headroom is roughly 6 us at
4 MB rather than under one. Before investing in the Rust-side work, confirm the mechanism
cheaply: run the same cuFFT plan over a buffer we allocate ourselves versus the loaned iceoryx2
buffer, in one process, interleaved. If the placement theory is right the gap reproduces with
no gRPC involved at all, and if it does not reproduce, the cause is somewhere else entirely and
the Rust work is unnecessary. That experiment is cheap and nobody has run it.

## 7b. i-RDMA: can the data land in GPU memory instead? (measured 2026-08-18)

The idea: stop reading the transform's input from host memory and have it arrive in
GPU-resident memory instead. Two premises have to be corrected before reading any of this.

**We already have no GPU copy.** The optimized path logs `feed mode : in-place (no copy)`.
The staging copy was removed by `--zc-align`. There is nothing left to delete.

**DAQiri does not write to the GPU either.** From `bench_daqiri_roce_pipeline.cc`:
"DAQiri host_pinned MRs are cudaMallocHost'd". Its receive buffers are host memory, mapped
to a device pointer and transformed in place, exactly like ours. Its `cudaMalloc` calls are
for the FFT *output*. This is why the placement ladder found the two identical. Matching
DAQiri is not the prize here; the prize is going past it, because it is stuck in host memory
too and has no route out that we do not also have.

### What was measured

`fft/bench_fft_memsrc.cc` was extended to time the producer's WRITE as well as the transform,
because in the pipeline benchmark the write falls outside the measured window. An arm that
writes slowly and transforms quickly would look like a pure win while being neutral or worse.
The verdict is therefore taken on write + transform, never on the transform alone.

At 4 MB, 5 sizes x 5 reps, arms rotated every iteration, alignment held at 2 MB for all:

| arm | write | transform | total |
|---|---|---|---|
| `hostalloc` (DAQiri's kind) | 173.36 | 60.42 | **236.78** |
| `shmreg` (what we get today) | 217.81 | 69.60 | **287.60** |
| `mgdwrite` (managed, preferred location GPU) | 192.31 | 70.43 | **263.41** |
| `device` (cudaMalloc, reached by copying) | 448.71 | 43.52 | **492.23** |
| `devwrite` (cudaMalloc, CPU stores into it) | FAULTS | FAULTS | FAULTS |

Three findings, in order of how much they constrain the design:

1. **The CPU cannot store into `cudaMalloc`'d memory on GB10.** A guarded one-byte probe
   (SIGSEGV/SIGBUS handler plus `siglongjmp`, so the sweep drops the arm instead of dying)
   faults at every size. Any design where a CPU-side producer writes directly into device
   memory is impossible on this hardware. Only a DMA engine can put bytes there.
2. **Copying your way there is dead by two orders of magnitude.** The `device` arm has the
   fastest transform by far, 43.52 vs 69.60, but pays 448.71 to get the bytes in. Total is
   492.23 against 287.60. The decision rule was "dead if the write penalty exceeds 6.10 us";
   the penalty is +230.90.
3. **Managed memory does not deliver device residency.** `mgdwrite` sets
   `cudaMemAdviseSetPreferredLocation` to the GPU and prefetches there, and its transform is
   still 70.43, indistinguishable from ordinary host memory. The CPU write migrates the pages
   straight back. Route C is not merely risky in theory, it was measured and it does not work.
   Sign test against every other arm: p = 1 throughout.

### How much is actually on the table

Two numbers, and the difference between them matters:

* **6.10 us at 4 MB** (47.55 vs 53.66) from the read-only ladder, where nothing wrote to the
  buffer beforehand.
* **26.08 us at 4 MB** (43.52 vs 69.60) from this run, where a CPU store dirtied the host
  buffer before each transform.

The second figure flatters the idea. Our CPU-store producer dirties host caches in a way a
DMA producer would not, and DAQiri's producer is a NIC, not a CPU. **Cite 6.10 us as the
conservative floor.** It is still the entire size of our remaining gap, so a working
device-landing path would put gRPC-Direct ahead of DAQiri rather than level with it.

### NUMA and page attributes: closed, not deferred

The premise was that on a coherent part "device" versus "host" memory might be a page
attribute rather than a physical location, reachable with `mbind` without touching Rust:

```
$ numactl --hardware
available: 1 nodes (0)
node 0 size: 122571 MB
```

One node covering all 122 GB. GPU memory is not a separate NUMA node, so there is no node to
bind to and `move_pages` would report node 0 for every page by construction. No probe was
built because there is nothing it could report. Closed.

### The three routes, costed

| | Route B: GPUDirect RDMA | Route A: device-resident arena | Route C: managed memory |
|---|---|---|---|
| **Blocker** | `GRPC_DIRECT_TRANSPORT_RDMA = 3` exists in `grpc_direct.h` but the header says twice: "not yet implemented, returns NULL". Behind Cargo `--features rdma`, via easyrdma. | The iceoryx2 arena is allocated inside the Rust library with `shm_open`/`mmap`. We receive a pointer; we never choose where it lives. Same FFI seam as section 7. And per finding 1, the CPU could not write there anyway, so the producer would have to become a DMA engine, which collapses this into Route B. | None. Fully implementable today. |
| **Effort** | Large. Implementing an RDMA transport in the Rust library, then registering device memory with the NIC (nvidia_peermem or dma-buf). | Large, and probably pointless on its own. | Already done. It took an afternoon. |
| **Risk** | The transform gain is real but the floor is 6.10 us, not 26. Needs a second box or a loopback RoCE setup to be meaningful. | Blocked and likely subsumed by B. | **Retired.** Measured, does not work, pages migrate back on CPU write. |
| **Rank** | **First.** It is the architecturally correct answer for a real instrument: the producer is a DMA engine that must write the bytes somewhere regardless, so choosing GPU memory as the destination is free and the 6.10 us is genuine rather than moved around. | Second, conditional on B. | Last. Do not revisit without new evidence. |

Nobody should start Route B expecting a quick win. It is the right design, it is a real piece
of work in a Rust library we do not own, and the payoff is about 6 us at the largest payload.

## 8. A bug that made a failure look like a win (read this before adding kernels)

`CMAKE_CUDA_ARCHITECTURES` was hard-coded to **90** (Hopper) in both CMakeLists and both build
scripts, but the GB10 is **compute capability 12.1 (sm_121)**. Every custom CUDA kernel in the
repo failed to launch with `cudaErrorNoKernelImageForDevice`, silently. cuFFT masked it
entirely because NVIDIA ships fat binaries, so nothing ever looked broken.

The first E3 run "won" at 53.9 us with an **all-zero spectrum**: the copy kernel never ran and
the FFT transformed untouched memory.

Fixed: arch is now `native` in `CMakeLists.txt`, `grpc_direct/CMakeLists.txt`,
`scripts/build.sh`, `scripts/build_grpc.sh`; the `build_grpc` dir is configured with
`-DCMAKE_CUDA_ARCHITECTURES=121`; and `launch_realign_copy` now does
`CUDA_CHECK(cudaGetLastError())` after the launch. **Always error-check kernel launches here.**

## 9. Environment and exact commands

**Machine:** DGX Spark `spark-ac69`, NVIDIA GB10 Grace-Blackwell, sm_121, CUDA 13 at
`/usr/local/cuda-13/bin`, aarch64. Coherent C2C so host VA == device VA.
GPU clocks **cannot** be locked (`nvidia-smi -lgc` needs privileges we lack).

**Access:** `nitest@spark-ac69.ni.corp.natinst.com`, key auth, **no password, no passwordless
sudo.** Repo at `/home/nitest/daqiri_gpu`, build dir `build_grpc/`.

```powershell
# Windows: use full paths, they are not on PATH
$ssh="C:\WINDOWS\System32\OpenSSH\ssh.exe"; $scp="C:\WINDOWS\System32\OpenSSH\scp.exe"
```

```bash
# Runtime env needed by every gRPC binary
export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:$LD_LIBRARY_PATH"

# Build
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
cmake --build ~/daqiri_gpu/build_grpc --parallel 16 --target bench_grpc_server

# Clean shared memory between runs (REQUIRED, runs cross-kill otherwise)
pkill -9 -f bench_grpc_server; rm -rf /tmp/iceoryx2; rm -f /dev/shm/iox2_*; sleep 1
```

**SSH gotchas learned the hard way:**
- Always `scp` a script file and run `bash /tmp/x.sh`. Inline multi-line compound commands get
  mangled.
- Inline `pkill -9 -f bench_grpc_server` over ssh kills your own remote shell. Use it only from
  inside a script file.
- Add `-o ConnectTimeout=N`.
- `.gitattributes` forces LF on `*.sh` and `*.py` so Windows checkouts do not break bash on
  Spark. Do not remove it.
- Check `pgrep -af bench_` is empty before launching; concurrent sweeps cross-kill each other.

**Repro scripts** (all take `SIZES=` and most take `ARMS=` as env overrides):

| Script | What it does |
|---|---|
| `scripts/headline_sweep.sh` | **The headline artifact.** 9 sizes x 3 arms (base / optimized / DAQiri) x `REPS` reps (default 2), arms interleaved within each rep. Aborts if the server binary is missing, older than its source, or predates `--opt-stream`. Stamps the git SHA on every row. Writes `data/headline_runs.csv`. |
| `scripts/headline_table.py` | Turns that CSV into the scoreboard, the cuFFT-vs-transport gap decomposition, and paired sign tests. |
| `scripts/trio_probe.sh` | Arms cur/nl/st/af/all with a correctness pass. Interleaves if you pass `ARMS='cur all cur all cur all'`. |
| `scripts/drop_probe.sh` | Delivery accounting: received, missing, gap events, mean run length, across paces. |
| `scripts/check_drop_bias.py` | Local. Checks sequence **contiguity** in `data/*.csv`, not just row count. |
| `scripts/phase0_probe.sh` | Residual attribution with `--stage-timing`. Prints the verdict block. |
| `scripts/e12_probe.sh` | Arms base/e1/e2/e12. Produced the original alignment-fix result. |
| `scripts/e34_probe.sh` | Arms e2/e3/e4/e34 plus a correctness pass. |
| `scripts/verify_e2.sh` | Spectral correctness: copy vs realign vs in-place. |
| `scripts/decompose_4mb.py` | Local. Reads `data/*.csv`, prints the residual decomposition. |
| `scripts/grpc_sweep.sh`, `scripts/roce_sweep.sh` | Older single-transport sweeps. **Not interleaved with each other.** Use `headline_sweep.sh` for any gRPC-vs-DAQiri claim. |

## 10. What to do next

Most of the original list is done. What is genuinely left:

1. **Find out why our cuFFT is slower than DAQiri's.** This is now the whole ballgame: it is
   79% of the remaining gap at 4 MB and it scales with payload size (section 5). The cheapest
   decisive experiment is the placement A/B described at the end of section 7, which needs no
   gRPC and no Rust changes. If placement is not the cause, check whether the two processes
   pick different cuFFT plans by dumping the plan's work-area size and chosen algorithm at
   each size in both binaries.
2. **Attack the residual floor.** We sit near 5.5 to 6.7 us against DAQiri's 4.9, so this is
   worth 0.3 to 1.7 us, smaller than item 1 but fully ours to fix. `--opt-stream` took the
   easy part. What is left is per-message CUDA event record/query overhead and the metrics
   bookkeeping. Consider whether the two events per buffer are both needed.
3. **The small-buffer drops are benign and can be deprioritised.** See the note below.

Deliberately not on this list: the arena (section 7, blocked), and E1/E3/E4 (section 6,
measured and rejected).

**On the drops.** Only 170 to 179 of 200 buffers are delivered at 256 KB and below, which
looked like it might bias the medians. It does not. The missing sequence numbers are all early
(roughly 1 to 26, plus a small cluster near 45 to 56) and nothing is lost after about seq 56 in
a 250-message run. Every measured window is contiguous, so we measure ~171 *consecutive*
messages instead of 200: a smaller sample, not a biased one. The decisive evidence that this is
a startup/attach transient rather than latency-correlated shedding is that the 35%-faster arm
drops the *same* count as the slow arm (29 vs 29, 24 vs 23). A ring shedding under backlog
would shed less on the faster arm. Loss is also bursty (mean run length 12 to 14.5, not ~1),
raising the pace from 400 to 2000 us cuts it from 29 to 2, and there are zero drops at 4 MB.

## 11. Open questions (a teammate was asked for input on these)

1. ~~Why is `cudaHostRegister`'d heap memory ~10 us slower for a cuFFT read than
   `cudaHostAlloc`'d memory?~~ **Withdrawn.** The 10 us was thermal drift across runs. An
   interleaved run puts the two FFT times within 0.7 us. There is no ladder to explain.
2. Why does our cuFFT run ~4 us slower than DAQiri's at 1024 and 2048 KB specifically, but
   match at 4096 KB? This is the live version of question 1 and it is measured properly.
3. Can grpc-direct be made to allocate received messages into a supplied arena? See section 7:
   the answer from this side is no. The question is whether the Rust side wants to expose a
   seam.
4. Is ~52 GB/s expected for the copy engine reading mapped host memory on GB10? An SM kernel
   got ~102 GB/s.
5. Is "cuFFT R2C accepts an 8-byte-aligned input" safe to rely on, or UB that happens to work?
   We probe at runtime and fall back, so we are safe either way, but it would be good to know
   whether the fallback can ever trigger.
6. Can anything be done about the unlockable clocks? Every methodological contortion in
   section 1 exists because of that one missing privilege.

## 12. File map

| File | Role |
|---|---|
| `grpc_direct/bench_grpc_server.cc` | The hot path. `StreamBuffersPerMessage` is the shmem handler; `ShmemSession` holds per-session state; `FinalizeShmemSession` prints the teardown report including the Phase 0 block. |
| `fft/cufft_executor.{h,cu}` | `CuFFTExecutor(n, own_stream)`. With `own_stream` it creates a non-blocking stream, calls `cufftSetStream`, and completes by spinning on `cudaEventQuery` instead of `cudaEventSynchronize`. Also has `try_execute()` (non-throwing, used by the E2 alignment probe) and `launch_realign_copy()` (the E3 kernel). |
| `grpc_direct/bench_grpc_client.cc` | Builds a fresh `BufferRequest` inside the send loop and does a full CPU copy per iteration. Excluded from server e2e but caps throughput. Has `--pace-us` (default 400). |
| `grpc_direct/pipeline_fft.proto` | `samples` is field 1 (`FloatArray`), `raw_samples` is field 4 (`bytes`). |
| `PROGRESS.md` / `SHORTTERM_CONTEXT.md` / `LONGTERM_CONTEXT.md` | Updated, gitignored. |

## 13. Benchmark parameters (keep these constant for comparability)

N=200 measured, W=50 warmup, pace 400 us, client `taskset -c 11`, transport shmem,
`--one-shot`. Sizes 4096 to 1048576 samples (16 KB to 4 MB). DAQiri comparison numbers come
from `data/daqiri_roce_{mode}_{size}.csv`, gRPC from `data/grpc_{mode}_{size}.csv`.
