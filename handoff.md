# HANDOFF — gRPC-Direct latency optimization (CURRENT, 2026-08-17)

> Paste this into a new chat to continue. It is self-contained: everything a fresh session
> needs about the goal, the system, what has been measured, and what to do next.
> The previous RoCE-era handoff is preserved at `handoff_roce_2026-08-06.md`.

---

## 0. One-line status

gRPC-Direct was 2x slower than DAQiri at 4 MB. We found the cause (an incorrect alignment
assumption forcing an unnecessary GPU copy on 100% of messages), fixed it, and closed about
80% of the gap. Three other optimization ideas were measured and rejected. The remaining
~12 us is inside the FFT itself and depends on where the payload is allocated.

## 1. What we are trying to do

Make gRPC-Direct's end-to-end latency match or beat DAQiri's RoCE path, while:

- keeping the gRPC API structurally the same (optimize on top of it, do not replace it),
- putting every optimization behind an opt-in mode flag so the baseline stays measurable,
- proving correctness (spectral output) before trusting any speedup.

The cross-machine RoCE test from the previous arc is shelved. Do not restart it.

## 2. Where the work lives

- **Branch:** `grpc-direct-optimization`, cut from `main` at 57ba6d3. **`main` is untouched.**
- **Commits on the branch:**
  - `5eaaf89` instrument the residual + fix the alignment rule (Phase 0, E1, E2)
  - `4de101c` E3/E4 measured and rejected + fix wrong CUDA arch
- **Nothing has been pushed.** Ask before pushing. Git identity: Dami Thomas,
  damithomas03@gmail.com. Remote `https://github.com/dvthomas01/DAQIRI_v_GRPC.git`.
- **Note:** `PROGRESS.md`, `SHORTTERM_CONTEXT.md`, `LONGTERM_CONTEXT.md` are in `.gitignore`
  by existing repo convention. They are updated on disk but intentionally not committed.
- **Also note:** the previous RoCE session left a lot of uncommitted work in the working tree
  (RoCE pipeline sources, `data/*.csv`, `presentation/`, many `scripts/probe_*.sh`). It is
  untracked and shared across both branches. It was deliberately left alone. Do not commit it
  to the optimization branch.

## 3. How we found the problem (the reasoning that mattered)

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

## 4. Current scoreboard (p50 us)

| size | before | after E2 | speedup | DAQiri | remaining gap |
|---|---|---|---|---|---|
| 16 KB | 17.3 | **12.4** | 1.39x | 11.5 | 0.9 |
| 256 KB | 26.6 | **23.8** | 1.12x | 20.9 | 2.8 |
| 4 MB | 127.2 | **75.9** | **1.67x** | 63.7 | 12.2 |

p99 improved at every size too (4 MB: 144.7 to 86.9 us). Gap to DAQiri went from 62.6 us to
12.2 us. Correctness verified: top-3 spectral peaks identical to the CPU-copy ground truth at
all sizes, to every printed digit.

**Where the remaining 12 us lives.** Not in the transport. It tracks where the input buffer
is allocated. Same 4 MB R2C plan, same data:

| input memory | FFT time |
|---|---|
| `cudaMalloc`'d device memory | 45.6 us |
| `cudaHostAlloc`'d pinned host (what DAQiri uses) | 58.8 us |
| `cudaHostRegister`'d protobuf heap block (what we use) | 68.8 us |

DAQiri allocates one `cudaHostAlloc` region at init with slots strided by 64 KB, so alignment
and mapping are correct by construction. We register an arbitrary protobuf heap block.

## 5. Mode flags (all opt-in, baseline unchanged)

Server: `grpc_direct/bench_grpc_server.cc`.

| Flag | Experiment | Verdict |
|---|---|---|
| `--stage-timing` | Phase 0 attribution, prints a residual breakdown at teardown | keep, diagnostic |
| `--zc-align` | **E2:** probe cuFFT at runtime instead of assuming 16 B | **ADOPTED, the win** |
| `--zc-h2d` | **E1:** realign via H2D from pinned host instead of D2D | rejected: no change (76.6 vs 76.3), worse p99 |
| `--zc-kernel` | **E3:** SM grid-stride copy, then device-memory FFT | rejected: 110.8 vs 76.4 at 4 MB |
| `--zc-bigreg` | **E4:** register whole 64 KB GPU pages like DAQiri | rejected: 77.5 vs 76.4, no effect |

Pre-existing flags: `--port --bufsize --n-buffers --warmup --out --one-shot --transport
--zero-copy --zc-parse --verify`.

Rejection detail worth remembering:
- E1: D2D-from-mapped and H2D-from-pinned both hit the same ~52 GB/s wall. The copy engine is
  the limit, not the API choice.
- E3: the SM kernel copies at ~102 GB/s, genuinely double the copy engine, but it needs
  roughly 170 GB/s to pay for itself.
- E4: `cudaHostRegisterReadOnly` is rejected outright by the GB10 driver ("operation not
  supported"), so it was replaced by `--zc-bigreg`, which also did nothing.

## 6. A bug that made a failure look like a win (read this before adding kernels)

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

## 7. Environment and exact commands

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
| `scripts/phase0_probe.sh` | Residual attribution with `--stage-timing`. Prints the verdict block. |
| `scripts/e12_probe.sh` | Arms base/e1/e2/e12. Produced the headline 127.2 -> 75.9 result. |
| `scripts/e34_probe.sh` | Arms e2/e3/e4/e34 plus a correctness pass. |
| `scripts/verify_e2.sh` | Spectral correctness: copy vs realign vs in-place. |
| `scripts/decompose_4mb.py` | Local. Reads `data/*.csv`, prints the residual decomposition. |
| `scripts/grpc_sweep.sh` | Pre-existing full 9-size sweep. **Does not yet pass `--zc-align`.** |

## 8. What to do next

Pick one of these. They are ordered by cost, not by expected payoff.

1. **Cheap trio, none of which has been measured yet.** Each looks worth 1-3 us and all three
   should help the p99 tail, which is still poor (20-65 us at 16 KB against a 12.4 us p50).
   DAQiri does all three.
   - `--opt-nolock`: the shmem handler holds a **global `std::mutex` plus an `unordered_map`
     lookup keyed on `PipelineSummary*` for the entire message**. Drop it.
   - `--opt-stream`: we run cuFFT on the **legacy null stream** and block on
     `cudaEventSynchronize` per buffer, with no `cufftSetStream`. Give it a dedicated
     non-blocking stream.
   - `--opt-affinity`: pin the handler thread to a fixed core.
2. **Make `--zc-align` the default**, or at minimum wire it into `scripts/grpc_sweep.sh`, and
   re-run the full 9-size sweep so there is one clean headline table instead of three
   partial runs.
3. **The arena idea, the only lever aimed at the remaining 12 us.** Get the payload into
   `cudaHostAlloc`'d memory like DAQiri: a `google::protobuf::Arena` whose initial block sits
   inside a pre-registered `cudaHostAlloc` region. **Blocker:** we only receive a
   `const BufferRequest*` from grpc-direct, so we do not control where protobuf allocates.
   Needs a hook from grpc-direct, or a change on their side. Confirm feasibility before
   spending time on it.
4. **Fix the small-buffer drops.** Only 170-179 of 200 buffers are delivered at 256 KB and
   below. Full 200/200 only at 4 MB. This is a fire-and-forget ring with no flow control;
   DAQiri uses credit-bounded pre-posted receives.

## 9. Open questions (a teammate was asked for input on these)

1. Why is `cudaHostRegister`'d heap memory ~10 us slower for a cuFFT read than
   `cudaHostAlloc`'d memory of the same size? Page-rounding the registration did not help, so
   the "mapping granularity" theory looks wrong.
2. Any way to improve that mapping without controlling the allocator?
3. Can grpc-direct be made to allocate received messages into a supplied arena?
4. Is ~52 GB/s expected for the copy engine reading mapped host memory on GB10? An SM kernel
   got ~102 GB/s.
5. **Unexplained measurement.** In the E3 arm the FFT over `cudaMalloc`'d device memory
   measured 63.2 us, but the same buffer type measured 45.6 us in the earlier run. Suspect a
   clock drop after the memory-bound kernel. **Consequence: prefer within-run arm-to-arm
   comparisons over cross-run ones.** The 127.2 -> 75.9 headline is a within-run pair.
6. Is "cuFFT R2C accepts an 8-byte-aligned input" safe to rely on, or UB that happens to work?
   We probe at runtime and fall back, so we are safe either way, but it would be good to know
   whether the fallback can ever trigger.

## 10. File map

| File | Role |
|---|---|
| `grpc_direct/bench_grpc_server.cc` | The hot path. `StreamBuffersPerMessage` is the shmem handler; `ShmemSession` holds per-session state; `FinalizeShmemSession` prints the teardown report including the Phase 0 block. |
| `fft/cufft_executor.{h,cu}` | `execute()` blocks on `cudaEventSynchronize` on the null stream. Added `try_execute()` (non-throwing, used by the E2 probe) and `launch_realign_copy()` (the E3 kernel). |
| `grpc_direct/bench_grpc_client.cc` | Builds a fresh `BufferRequest` inside the send loop and does a full CPU copy per iteration. Excluded from server e2e but caps throughput. Has `--pace-us` (default 400). |
| `grpc_direct/pipeline_fft.proto` | `samples` is field 1 (`FloatArray`), `raw_samples` is field 4 (`bytes`). |
| `PROGRESS.md` / `SHORTTERM_CONTEXT.md` / `LONGTERM_CONTEXT.md` | Updated, gitignored. |

## 11. Benchmark parameters (keep these constant for comparability)

N=200 measured, W=50 warmup, pace 400 us, client `taskset -c 11`, transport shmem,
`--one-shot`. Sizes 4096 to 1048576 samples (16 KB to 4 MB). DAQiri comparison numbers come
from `data/daqiri_roce_{mode}_{size}.csv`, gRPC from `data/grpc_{mode}_{size}.csv`.
