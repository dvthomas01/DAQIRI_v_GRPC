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
control. At 4 MB we are now within about 3 us, roughly 4%.

**If you read only one more thing, read section 1.** Two of this project's headline numbers
turned out to be measurement artifacts rather than results, and both were caught late.

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

> **This section previously reported a 12.2 us gap at 4 MB and a memory-source ladder
> explaining it. Both were wrong.** They came from a gRPC sweep and a DAQiri sweep run
> back to back rather than interleaved, so the arms drifted apart thermally and the drift was
> read as a result. The table below is from a single interleaved run. If you have quoted the
> 12.2 us figure anywhere, correct it.

All three arms measured adjacently at each size, one thermal window:

| KB | base | optimized | DAQiri | speedup | gap | gRPC resid | DAQiri resid |
|---|---|---|---|---|---|---|---|
| 16 | 16.99 | **13.18** | 11.41 | 1.29x | +1.78 | 5.66 | 4.94 |
| 32 | 18.26 | **15.01** | 12.42 | 1.22x | +2.59 | 5.73 | 5.09 |
| 64 | 21.62 | **17.54** | 15.47 | 1.23x | +2.06 | 5.76 | 4.91 |
| 128 | 27.25 | **23.81** | 22.06 | 1.14x | +1.74 | 5.82 | 4.91 |
| 256 | 27.60 | **24.27** | 20.62 | 1.14x | +3.65 | 5.81 | 4.88 |
| 512 | 35.47 | **29.02** | 26.03 | 1.22x | +2.99 | 5.79 | 5.04 |
| 1024 | 47.15 | **33.92** | 28.29 | 1.39x | +5.63 | 5.98 | 4.93 |
| 2048 | 67.63 | **42.43** | 37.07 | 1.59x | +5.36 | 6.46 | 4.98 |
| 4096 | 126.42 | **71.98** | 69.07 | **1.76x** | +2.91 | 7.12 | 4.91 |

Throughput at 4 MB went from 33,055 to 57,944 MB/s. Correctness verified: top-3 spectral peaks
identical to the CPU-copy ground truth at every size, to every printed digit.

**The three corrections this run forced.**

1. **The gap at 4 MB is 2.91 us (4.2%), not 12.2 us.**
2. **The two cuFFT times are nearly identical** (64.86 vs 64.16 at 4 MB, a 0.7 us difference).
   The memory-source ladder was a cross-run artifact. Whatever is left is not the transform.
3. **The gRPC residual is now flat**, 5.66 rising to 7.12, matching the shape of DAQiri's 4.88
   to 5.09. Before the fix it grew 8.11 to 81.46. The size-dependent cost is gone entirely;
   what remains is a fixed offset.

**So the remaining gap is the residual difference**, roughly 0.8 to 2.2 us, and it is launch
and completion overhead rather than anything size-dependent. That is what the trio was aimed
at, and `--opt-stream` recovered 0.15 to 0.39 us of it.

**Still unexplained.** At 1024 and 2048 KB our cuFFT runs about 4 us slower than DAQiri's
(27.94 vs 23.36, 35.97 vs 32.10) while at 4096 KB the two match. The gap is widest at exactly
those two sizes. Nobody has explained this.

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

**Why it also stopped being worth much.** The original case for the arena was the 12.2 us gap
and the memory-source ladder that appeared to explain it. The interleaved run killed both. Our
cuFFT and DAQiri's cuFFT are within 0.7 us at 4 MB, so even a perfect fix to payload placement
has well under a microsecond of headroom, not ten.

**Status: blocked, and low value even if unblocked.** The honest framing for a writeup is that
going from 63 us behind to about 3 us behind with a root cause explained is the result, and
"the last microsecond is memory placement, blocked by allocator ownership across an FFI
boundary" is a legitimate place to stop.

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
| `scripts/headline_sweep.sh` | **The headline artifact.** 9 sizes x 3 arms (base / optimized / DAQiri) x 3 reps, arms interleaved within each rep. Writes `data/headline_runs.csv`. |
| `scripts/headline_table.py` | Turns that CSV into the scoreboard plus paired sign tests. |
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

1. **Explain the 1024/2048 KB anomaly**, where our cuFFT runs ~4 us slower than DAQiri's while
   matching at 4 MB. It is the largest unexplained item on the board and it sits exactly where
   the gap is widest. Start by checking whether the two are picking different cuFFT plans or
   different transform decompositions at those sizes.
2. **Attack the residual floor.** We sit near 5.5 to 6.6 us against DAQiri's 4.9. `--opt-stream`
   took the easy part. What is left is per-message CUDA event record/query overhead and the
   metrics bookkeeping. Consider whether the two events per buffer are both needed.
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
