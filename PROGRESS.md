# PROGRESS — DAQiri GPU FFT Pipeline
**Project:** NVIDIA DAQiri → GPU FFT Benchmark  
**Updated:** 2026-08-24 (**Pacing was an uncontrolled treatment, and Table B was wrong because of it.** Checking whether extbuf and DAQiri ran the same FFT, which §7l had flagged as the first thing to check, found they do: same `CuFFTExecutor`, same R2C plan, same n, same memory class, and alignment ruled out by measurement rather than argument. So §7l's third limit is **withdrawn** and the 4 MiB gap is real. Checking it turned up the actual fault: extbuf's transform **triples** between 100 and 400 µs of send pacing while DAQiri's does not move, and `headline_sweep.sh` had `PACE` hardcoded at 400, inside one arm's degradation region and outside the other's. Table B was therefore an unpaced arm against a 400 µs paced arm. Re-run interleaved, all four arms in one rotation at `PACE=25`, **DAQiri is faster at every size and two rows change sign**: 16 KB goes from -2.07 to +1.28 and 256 KB from -1.01 to +2.59. The §7l crossover was an artefact of two harnesses. Separately, **every rate claim in the document was audited** against the mean/median rule: the 256 KB "97.6 percent of wire" and the 1 MiB 10792-13517 MiB/s are withdrawn, and the 4 MiB 5878 becomes 5796-5803. The **deck's 5.775 against 5.785 GB/s tie is retracted**: both numbers are Gate 3's fabric at a misconfigured 1024-byte MTU, so both arms were resting on the same artificial wall. At MTU 4096 the same fabric does 98.0 percent of line rate, which is what the deck says now. One number stays open, extbuf's 14 µs at 4 MiB, with **both named candidates tested and ruled out**. handoff.md §7n through §7q.)

<!-- historical header line -->
**Previously:** 2026-08-21 late (**The pipeline runs at the wire, and the reason the earlier fix worked was not the reason given.** Two corrections to this morning's entry, both from paired measurement. First: 7i said the receiver's spectral check cost 3.18x because it held the slot inside the credit window. Moving it below the re-queue dropped `hold_us` from 2488 µs to 1.5 µs and **the rate did not move at all**. The credit window was never the mechanism. The receiver is one thread, `detect_peaks` costs about 2400 µs of it per message at 4 MiB, and the next receive waits on it wherever in the loop it sits. The 3.18x from the flag stands; the explanation for it is retracted. Second: removing the sender's own frame-build memcpy (`--gen inplace`) takes 4 MiB from 4989 to **5878 MiB/s median, three of three**, with an inter-arrival of 663-686 µs against a **685 µs wire time**. Gate 3 measured 5843 MiB/s. **The pipeline is at line rate.** The "85 percent of link" was the harness measuring its own memcpy, not a transport limit. The server now **withholds** the rate lines when `--poison on` or `--verify every` rather than printing them with a caveat. handoff.md §7j. *The 5878 figure is corrected to 5796-5803 by the 2026-08-24 audit, §7p; it was one over a median gap, not a rate. The claim survives, but it now sits just under Gate 3's 5843 rather than over it.*)

<!-- historical header line -->
**Previously:** 2026-08-21 (**The pipeline has a transport number for the first time, and the sender's stall turned out to be ours.** Every latency figure this project produced before today started its clock after the data had landed. Post-to-FFT-complete from the PXI at 4 MiB is now measured at about **1364 µs unloaded**, by round-trip echo on the sender's single clock, because the two boxes' realtime clocks differ by 23.13 seconds and neither runs NTP. The 2205 µs the sender spent blocked per 4 MiB buffer was **the receiver's own spectral check holding the slot between the transform and the re-queue**: moving it out is worth **3.18x**, taking the path from 27 percent of line rate to **85 percent**. Slot depth is closed negative, 2 through 16 slots are one distribution. What limits it now is the sender's own CPU doing two 4 MiB host memcpys per message. Phase 4's cell ran with verification on, so **its throughput and blocked-send figures are contaminated and must not be quoted**; its latency columns are unaffected. handoff.md §7i.)

<!-- historical header line -->
**Previously:** 2026-08-20 (Phase 7 complete. **Phase 1 (the flag experiment) is negative**: no `cudaHostRegister` flag recovers any part of the penalty, and the penalty turns out not to exist below about 1 MB, so the 10.94 µs figure only ever meant 10.94 µs **at 4 MB**. **Phase 2 (the minimal RDMA data path) passes**: 31,800 messages from the PXI landed in a `cudaHostAlloc`'d pool on the Spark and were spectrally verified, with zero completion errors and nothing allocated or registered after startup. The deliberately-broken-ordering control was run *first* and fails as required, which is what makes the green runs mean anything. Next is Phase 3, integration into the Rust transport. The Spark went off the network briefly and is back at the same address; both machines are up and the RoCE fabric is verified end to end. **The PXI's undocumented copy of `grpc-direct` has been audited against upstream**: 125 of 127 files are byte-identical to `ni/grpc-direct` HEAD `2d404a5`, the only modified source file is `src/lib.rs` at +529/-31, and the four `lib.rs.bak` snapshots were hiding nothing.)

> **This file is committed.** It used to be gitignored while three tracked documents pointed
> readers at it, which made it a handoff artifact nobody outside this machine could read. See
> the note at the end of Milestone Status.

---

<!-- historical header line, kept so the earlier entries below read in context -->
**Previously:** 2026-08-19 (Phase 6 gates **all four passed**. The NIC accepts `cudaHostAlloc`'d memory and rejects device memory, the fabric runs at 98% of line rate, and the host pointer is directly usable by the GPU. The architecture is feasible; next step is the flag experiment. Phase 5 closed earlier the same day: **mechanism found**. `cudaHostAlloc` beats `cudaHostRegister` by 10.94 µs of transform time at 4 MB, larger than the whole remaining 8.10 µs gap. That retracted the earlier "memory kind is dead" null, which came from a read-only ladder that never dirtied the buffer. Page size, NUMA, wait method and device-landing are all eliminated.)

---

## Milestone Status

| ID | Description | Status | Notes |
|---|---|---|---|
| **Phase 1 — Pipeline A (DAQiri)** | | | |
| M1 | cuFFT executor + validation | **COMPLETE** | `fft_validate` PASSED on Spark — 9.28 µs FFT (N=16384), all 3 tones detected |
| M2 | Signal generator (host) + CSV logger | **COMPLETE** | signal_gen, metrics.h, csv_logger, buffer_pool built and linked cleanly |
| M3 | DAQiri session init + synthetic buffer injection | **COMPLETE** | socket loopback PASSED: 100 TX, 1638400 bytes RX (zero loss), ~0.16 MB/s |
| M4 | DAQiri → CUDA device memory path (DMA registration) | **COMPLETE** | socket→H→D→cuFFT PASSED all 4 sizes; p50 E2E: 22µs (4K) → 58µs (32K); 8 figs |
| M5 | End-to-end Pipeline A running, metrics captured | **COMPLETE** | CPU util 2–4%, GPU util ~0% (expected for µs bursts); all 4 sizes PASSED |
| M6 | Buffer-size sweep (4096–32768) + Nsight profiling | **COMPLETE** | 6 Nsight figures; actual GPU kernel time: 2.4/3.3/5.9/9.9 µs (4K→32K); H→D GPU DMA: ~1.1 µs (4096); CUDA-event overhead confirmed |
| **Phase 2 — Pipeline B (gRPC Direct)** | | | |
| M7 | Adapt gRPC Direct C++ server to accept float32 buffers | **COMPLETE** | `bench_grpc_server.cc`: `StreamBuffers` (standard gRPC) + `StreamBuffersPerMessage` (shmem / gRPC Direct) |
| M8 | cudaMemcpy host→device path in gRPC server | **COMPLETE** | Pinned staging + CUDA-event-timed H→D; byte-identical code in both transports |
| M9 | End-to-end Pipeline B running, metrics captured | **COMPLETE** | Both transports; matched-pace fair comparison; wire-latency metric (`send_timestamp_ns`→recv) added |
| M10 | Buffer-size sweep (4096–32768) + Nsight profiling | **PARTIAL** | 4 sizes × 2 transports × 3 trials done; Nsight profiling for Pipeline B not re-run |
| **Phase 3 — Comparison & Report** | | | |
| M11 | Side-by-side CSV output | **COMPLETE** | `data/mc_*.csv` + `scripts/aggregate_matched.py` |
| M12 | Visualization scripts | **COMPLETE** | `scripts/plot_m9_comparison.py` → `data/figures/fig_m9_01..06.png` |
| M13 | Final comparison report | **COMPLETE** | [M9_REPORT.md](M9_REPORT.md) |
| **Phase 4 — gRPC-Direct latency optimization** (branch `grpc-direct-optimization`) | | | |
| P0 | Instrument and attribute the gRPC/DAQiri gap | **COMPLETE** | `--stage-timing`. Killed the re-pinning hypothesis; found a realign copy on 100 % of messages worth 77 µs at 4 MB |
| E1 | Realign via H2D from pinned host instead of D2D | **REJECTED** | `--zc-h2d`. No change (76.6 vs 76.3 µs copy cost); p99 got worse |
| E2 | Probe cuFFT for real alignment instead of assuming 16 B | **COMPLETE — ADOPTED** | `--zc-align`. 4 MB e2e 127.2 → 75.9 µs (**1.67×**); spectrally verified identical |
| E3 | SM-kernel copy → device-memory FFT | **REJECTED** | `--zc-kernel`. 110.8 vs 76.4 µs. Kernel copies at ~102 GB/s, needs ~170 to pay off |
| E4 | Improve source mapping quality | **REJECTED (re-confirmed)** | `--zc-ro` unsupported by the GB10 driver. `--zc-bigreg` re-measured properly 2026-08-18: 9/15 cells, p = 0.61. A true null, not a noisy one |
| BUG | CUDA arch was sm_90 on an sm_121 GPU | **FIXED** | Every custom kernel silently failed to launch; cuFFT masked it. Now `native` |
| **Phase 5 — measurement hardening & the cuFFT gap** (branch `grpc-direct-optimization`) | | | |
| H1 | Flip `--opt-stream` on by default, resolve the other two flags | **COMPLETE** | `zc_align` and `opt_stream` default true; `opt_nolock` and `opt_affinity` stay opt-in |
| H2 | 54-run headline sweep, 9 sizes × 3 arms × 2 reps, interleaved | **COMPLETE** | `data/headline_runs.csv`, all rows `OK`, single gitsha. Overturned two prior conclusions |
| H3 | Close the `n` shortfall question | **COMPLETE** | Head-truncated during warmup, not drops under load. 18/18 windows contiguous, 0 holes |
| H4 | Verify both arms run genuinely identical transforms | **COMPLETE** | Code read: same plan, same strides, out-of-place in both, output to device memory in both |
| H5 | Re-measure registration granularity (E4) | **COMPLETE — NULL** | `scripts/placement_probe.sh`. Mapping granularity exonerated |
| H6 | Decisive placement A/B, no gRPC, self-allocated vs loaned buffer | **COMPLETE** | `fft/bench_fft_memsrc.cc`. First pass read-only and null; **that null was wrong** |
| H7 | Spin vs blocking wait, one clean variable | **COMPLETE — PREDICTION REFUTED** | `scripts/spin_probe.sh`. Blocking lost at all 6 sizes (e2e 1/18, p = 0.000145). `--opt-stream` validated, no adaptive wait needed |
| H8 | Write-cost harness: time the producer write, not only the transform | **COMPLETE** | `data/memsrc_write.csv`. A CPU store into `cudaMalloc`'d memory **faults** on GB10; copy-to-device loses by ~231 µs at 4 MB |
| H9 | NUMA / page-attribute probe | **CLOSED, NOT RUN** | `numactl --hardware` = 1 node, 122571 MB. GPU memory is not a NUMA node, so there is nothing to `mbind` to |
| H10 | Managed memory with preferred location = GPU (Route C) | **RETIRED** | Transform still 70.43 µs, i.e. host speed. The CPU write migrates pages straight back |
| H11 | Page size vs allocation method, with `smaps` verification | **COMPLETE — MECHANISM FOUND** | `data/pagesize_rot.csv`. Page size innocent; `cudaHostRegister` guilty. 15/15, p = 6.104e-05 |
| **Phase 6 — RoCE transport into `cudaHostAlloc`'d buffers** (branch `grpc-direct-optimization`) | | | |
| G1 | Platform capability query + `nvidia-peermem` | **PASS** | Host ptr == device ptr. Also `GPU_DIRECT_RDMA_SUPPORTED=0`, `HOST_ALLOC_DMA_BUF_SUPPORTED=1`: device landing is impossible on GB10, host landing is the only route |
| G2 | Bring up `enp117s0`, confirm RoCE ACTIVE on both ends | **PASS** | Link came up on its own at 50 Gb/s. Needed a temporary IP, `192.168.20.2/24`, which does not survive reboot |
| G3 | `ib_write_bw` / `ib_write_lat` with ordinary host buffers | **PASS** | 1.81 µs small-message, 5843 MiB/s at 4 MB = 98% of line rate. Fabric is not the problem |
| G4 | `ibv_reg_mr` over a `cudaHostAlloc`'d buffer | **PASS** | Decisive. lkey/rkey `0x00182ae7`, addr and length match exactly. Control on device memory rejected with "Bad address" |
| **Phase 7 — RDMA transport, phased build** (branch `grpc-direct-optimization`) | | | |
| P0.5 | Re-frame the comparison as post-arrival processing latency | **COMPLETE** | `0c26669`. The 695 µs wire time is paid identically by both sides and cancels; the headline column is named for what it measures |
| P1 | Does any `cudaHostRegister` flag close the gap? | **COMPLETE — NEGATIVE** | `6070ae1`, `dc5eb4a`, `eb83fe9`. Allocation arms close 94–101% of the gap at every size, registration arms close ~0%. `Default`, `Portable`, `WriteCombined` all null. `ReadOnly` refused by the driver |
| P1b | Is the penalty size-dependent? | **COMPLETE — YES** | It does not exist below ~1 MB. Pooling nine sizes had turned a real 15 µs effect at 4 MB into p = 1. Every future quotation of the figure carries a payload size |
| P2 | Minimal RDMA data path, PXI → Spark → cuFFT, spectrally verified | **COMPLETE — PASSING** | `7a49963`. 1800 verified over nine sizes + 30000 in soak, 0 CQ errors, 0 timeouts |
| P2-ctrl | Deliberately-broken ordering must FAIL the verification | **COMPLETE — FAILS AS REQUIRED** | 59/60 wrong, reporting the 400 kHz poison tone. Ran *before* the real implementation. One 16 KB message in 20 passed anyway, so the test's sensitivity is size-dependent |
| P3 | Integrate into the Rust `grpc-direct` transport | **IN PROGRESS** | Scoping in `rdma_transport_plan.md` §6. Fork audited against upstream (§6.5). **Gate 5 PASSED** 17/17, 3 reps (§6.4): easyrdma accepts a `cudaHostAlloc` pool and the GPU reads the received bytes in place. Next: bind the FFI |
| P5 | Measure the transport, not just what happens after it | **COMPLETE** | `0f6c278`, `b8cdbe2`, `8912ac7`. Round-trip echo on the sender's single clock, plus receiver-side inter-arrival. Post-to-FFT-complete at 4 MiB ≈ **1364 µs unloaded**, 3/3, calibration subtracted paired. handoff.md §7i |
| P5b | Diagnose the sender's 2205 µs stall | **COMPLETE — IT WAS OURS** | `--verify off`: **1561→4925 MiB/s, 3.18x, 3/3, no overlap**. The flag is right. **The mechanism given here was wrong; see P5e** |
| P5c | Is four slots enough depth? | **COMPLETE — NEGATIVE** | 2, 4, 8 and 16 slots all land 4785–5149 MiB/s. One distribution. The most attractive candidate and the wrong one. P5e explains why it had to be flat |
| P5d | Generate in place on the sender | **COMPLETE — AT THE WIRE** | `ceb03b3`. `--gen inplace` removes the frame-build memcpy: `gen_p50` 467→0.16 µs, **4989→5878 MiB/s median, 3/3, no overlap**. `gap_p50` 663–686 µs against a **685 µs wire time**; Gate 3 measured 5843 MiB/s. The transport is not the bottleneck and the 85 % was the harness. handoff.md §7j |
| P5e | Was the credit window really the mechanism? | **COMPLETE — NO, RETRACTS P5b's REASON** | `detect_peaks` reads `d_out`, not the slot, so it was moved below the re-queue. `hold_us` **2488→1.5 µs** and the rate **did not move** (1611/1511/1576 vs 1561/1566/1458). One consumer thread; the next receive waits on the check wherever it sits. Extra slots cannot absorb it, which is also why P5c was flat. Server now **withholds** rate lines under `--verify every` or `--poison on` |
| P6 | Release-before-completion race | **DROPPED** | Analytic property, and P5c showed the pipeline runs fine at the depth where the race is describable. Window arithmetic preserved in handoff.md §10 |

**Note on this file's status.** `PROGRESS.md`, `SHORTTERM_CONTEXT.md` and `LONGTERM_CONTEXT.md`
were in `.gitignore` under "personal / local-only docs" while `handoff.md`,
`handoff_roce_2026-08-06.md` and `scripts/find_spark.sh` all pointed readers at them. They are
now committed, so those pointers resolve. `ARCHITECTURE.md`, `RESULTS.md` and `M9_REPORT.md`
remain local-only; the M13 row below links to one of them and that link will not resolve for
anyone else.

---

## Results Log

### Phase 5f — pacing was a treatment nobody controlled, and Table B was wrong (2026-08-24, commit `db315ad` and follow-on)

Four pieces of work, each one caused by the one before it. Full writeup in handoff.md §7n
through §7q.

**1. The cuFFT plan comparison came back the opposite of the way it was expected to.** §7l had
told the next reader that a real-to-complex against complex-to-complex mismatch would account
for the entire 4 MiB gap. It would have, and there is no mismatch. Both arms construct
`CuFFTExecutor`: same `cufftPlan1d` R2C, batch 1, default strides, out of place, output to
`cudaMalloc`'d device memory, one JIT warmup, plan built once. The sizes match once the units
are checked, which needed doing rather than assuming, because DAQiri's `--bufsize` and extbuf's
`--npts` are both in samples so 4 MiB is n = 1048576 in both. Alignment was ruled out by
measurement: `ha_off` minus `hostalloc` at a 256-byte offset over 5 interleaved reps came out
-0.10, -0.74, +0.58, -0.58, -1.73 µs, two of five positive. **§7l's third limit is withdrawn.**

**2. That work exposed the fault.** A smoke test put extbuf at 42.06 µs e2e at 16 KB against
9.63 in the published sweep. Warmup was eliminated first, `scripts/extbuf_warmup_probe.sh`
holding the measured window at 200 messages and varying only the warmup: 39.50, 40.40, 40.46,
41.78 µs for warmups of 50, 500, 2000, 20000. Then `scripts/pace_probe.sh`, arms rotated inside
each pace, found the cause. Extbuf's transform **triples** between 100 and 400 µs of send pacing
while DAQiri's holds flat, and `sm_mhz` was 2405 to 2548 in every cell so it is not the clock
gate. `PACE` was hardcoded at 400 in `headline_sweep.sh`, inside one arm's degradation region
and outside the other's. **The mechanism is unexplained and is now a first-class open question.**

**3. Table B re-run interleaved. Two rows change sign.** The §7l blocker was not actually gone:
`transport_cell.sh` never had a DAQiri arm, only `stream-loopback` had been added to it. Solved
the other way, by adding an `extbuf` arm to `headline_sweep.sh`, which already rotated `base`,
`opt` and `daq`. All four arms now run in one rotation, one thermal window, one message rate:
`REPS=3`, 1000 measured after 500 warmup, `PACE=25`. e2e medians in µs, positive delta means
DAQiri faster:

| KB | base | opt | daq | extbuf | old §7l delta | new delta |
|---|---|---|---|---|---|---|
| 16 | 15.744 | 11.376 | **9.456** | 10.736 | -2.07 | **+1.28** |
| 256 | 26.448 | 22.944 | **18.224** | 20.816 | -1.01 | **+2.59** |
| 1024 | 46.752 | 33.712 | **25.072** | 30.432 | +6.45 | +5.36 |
| 4096 | 129.745 | 71.504 | **68.976** | 94.144 | +41.83 | +25.17 |

**DAQiri is faster at every size, and the §7l crossover was an artefact of two harnesses.** At
16 and 256 KB the residuals are within 0.42 µs, so the whole gap at those sizes is transform
time. `opt` against `daq` at 4 MiB is now 2.53 µs where the old table had 8.10, and since their
cuFFT terms agree to 0.9 µs essentially all of what is left is residual, 6.51 against 4.85.
One caveat carried: the 16 KB `daq` figure rests on one rep, the other two having tripped the
`CLOCKLOW` gate at 2379 and 1560 MHz. Their raw values 9.408 and 9.344 agree with the kept
9.456, so the gate probably fired on a sampler artefact, the 0.2 s peak sampler missing a short
loaded window.

**4. Every rate claim in the handoff was audited against the mean/median rule** (§7p). Three
groups. Median-derived rates, where the fault applies: the 256 KB "97.6 percent of wire" and the
1 MiB 10792-13517 MiB/s are **withdrawn**; the 4 MiB 5878 becomes 5796-5803, which still stands
but now sits just under Gate 3's 5843 rather than over it; §7i's verify-cost absolute MiB/s is
withdrawn while its 3.18x paired ratio survives, and its attribution is corrected from
`ib_write_lat` to `ib_write_bw`. Span-derived rates are unaffected. **The rule: below 4 MiB on
this receive path, no median-derived rate is trustworthy.**

**5. The deck's tie is retracted, and the arithmetic says why.** The deck claimed gRPC-Direct
RDMA at 5.775 GB/s against DAQiri at 5.785 and called it a tie. 5.785 GB/s is 5518 MiB/s, and
Gate 3 measured this fabric at **5518.37 MiB/s with the RoCE MTU set to 1024**, which
`LONGTERM_CONTEXT.md` recorded in the same bullet where it called the number a hardware ceiling.
Both arms were resting on the same wall and the wall was a misconfiguration. Two transports
agreeing while pinned to a shared artificial ceiling is not evidence they perform alike. At MTU
4096 the same fabric does 5843.23 MiB/s, 6.127 GB/s, **98.0 percent of line rate**, which is
what the deck says now and is a stronger claim than the tie was.

**6. One number stays open, with both candidates ruled out** (§7q). At 4 MiB inside the rotation
the memory-class ladder is `base` 47.78 from device memory, `daq` 64.13 and `opt` 64.99 from
pinned host, `extbuf` 78.40 from pinned host. Zero copy costs about 16 µs at this size and that
is paid knowingly; extbuf's extra 14 is not explained. §7o's first candidate was wrong before it
was tested, `extbuf_fft_server.cu:315` defaulting `own_stream = false` with the harness never
passing `--own-stream`, so both arms ran the same mode. The second was tested with
`rdma/slotgeom_probe.cu`, which reproduces extbuf's pool exactly and splits the question into
stride, payload offset and working set across four arms rotated within each of 5 reps. Padding
the stride to 2 MB costs +0.35 and +0.16 µs; moving the payload off the 256-byte offset onto a
page boundary gains 0.26 µs in both runs. **The slot geometry costs nothing.** Because the probe
reproduces the pool exactly and still lands on the pinned-host rung, the 14 µs is **not in the
memory layout**, which narrows it to the live pipeline. Written up as open on purpose: two
candidates ruled out is a better handoff than two guesses.

An incidental result from the probe, worth not losing: a single re-transformed buffer is
consistently **slower** than cycling across four, by 3.8 and 10.1 µs, while its CPU write is 5
to 9 µs faster. Re-transforming one buffer keeps the lines dirty in CPU cache and the GPU pays
to snoop them. Single-buffer FFT microbenchmarks on this coherent part are measuring that.

---

### Phase 5d/5e — the pipeline reaches the wire, and a mechanism is retracted (2026-08-21 late, commit `ceb03b3`)

Two experiments in one cell, three reps, arms rotated, 4 MiB, 1000 measured messages, four
slots. `data/tc_inplace_1048576_s4.csv`.

**The credit window was not the mechanism.** Phase 5b attributed the 3.18x to `detect_peaks`
holding the received slot between the transform's gate and `slot_requeue`. That was testable.
`detect_peaks` reads `d_out`, which is `cudaMalloc`'d device memory holding the transform's
output, and never touches the slot, so it was moved below the re-queue.

| `stream` (`--verify every`) | hold p50 (µs) | MiB/s |
|---|---|---|
| check above the re-queue | 2488.58, 2480.34, 2666.04 | 1561, 1566, 1458 |
| check below the re-queue | 1.52, 1.26, 1.76 | 1611, 1511, 1576 |

`hold_us` fell by a factor of 1600 and the rate did not move. The receiver is one thread,
`detect_peaks` costs about 2400 µs of it per message at 4 MiB, and `receive_ext` cannot be
called again until it returns, so the arrival interval is the consumer's loop time regardless of
position. That is also why Phase 5c's depth sweep was flat: buffering absorbs bursts, and the
producer is not bursty, it is continuous and faster than us.

The reordering was kept, because it costs nothing and `hold_us` now measures the credit window
instead of measuring what we left inside it. The consequence that matters is that the fix is not
free: verifying every message at 4 MiB is not affordable inline at any position, and would need
sampling or a second thread.

**The sender's own copy was the entire remaining gap.** `--gen inplace` builds the sixteen
frames complete at startup and writes only a 16-byte header per message, removing one of the two
4 MiB host memcpys. Same server flags in both arms, so the receiver cannot tell them apart.

| arm | gen p50 (µs) | send p50 (µs) | gap p50 (µs) | MiB/s |
|---|---|---|---|---|
| `stream-nv` (`--gen copy`) | 467.12 | 335.70 | 783.51 | 5100 |
| `stream-inplace` | 0.16 | 688.20 | 662.98 | 6031 |
| `stream-nv` | 468.70 | 335.25 | 804.39 | 4973 |
| `stream-inplace` | 0.16 | 688.65 | 686.23 | 5829 |
| `stream-nv` | 467.40 | 336.79 | 801.67 | 4989 |
| `stream-inplace` | 0.13 | 687.99 | 680.29 | 5878 |

Three of three, no overlap. `gap_p50` of 663–686 µs against the 685 µs Gate 3 measured for
4 MiB, and 5878 MiB/s median against Gate 3's 5843 MiB/s. **The pipeline is at line rate.**
`send_p50` rising from 336 to 688 µs says the same thing from the sender's side: with the frame
build gone, the send call waits exactly one wire time.

This retires the "receive path sustains 85 percent of link" framing. The receive path is not the
limit and neither is the transport; the 85 percent was the harness measuring its own frame
build. A digitizer DMAs into the buffer it hands to the transport, so `--gen inplace` is the
more faithful arm as well as the faster one.

**Hardening.** The server now withholds the inter-arrival, sustained rate and consumer duty
lines when `--poison on` or `--verify every`, printing the reason and the two contrasting
numbers in their place, rather than printing a rate with a caveat. Confirmed: a `stream` rep run
after the change reports `mib_s NA`. `scripts/phase4_cell.sh` keeps `--verify every`, which is
correct for the latency columns it quotes, and can no longer produce a quotable rate.

### Phase 5 — the transport number, and the stall we were causing ourselves (2026-08-21, commits `0f6c278`, `b8cdbe2`, `8912ac7`)

Full writeup in `handoff.md` §7i. Driver `scripts/transport_cell.sh`, arms `echo`, `echo-cal`,
`stream`, `stream-nv`.

**Why the instrument had to be a round trip.** The PXI's realtime clock is 23.13 seconds ahead
of the Spark's and neither box runs NTP or chrony, so differencing wall clocks across the two
machines is worthless. The sender timestamps before it posts, the receiver acks 16 bytes
immediately after the transform's gate, the sender timestamps the ack. One clock throughout.
A calibration arm runs the same round trip with `--fft off` at 64 points and is subtracted
paired per rep.

| rep | echo rtt p50 (µs) | calibration (µs) | difference (µs) |
|---|---|---|---|
| 1 | 1379.05 | 109.39 | 1269.7 |
| 2 | 1438.43 | 23.47 | 1415.0 |
| 3 | 1390.98 | 26.76 | 1364.2 |

Median ≈ **1364 µs**, 3/3 positive. **Two caveats.** Waiting for the ack serialises the sender,
so this is *unloaded* latency and not the per-message cost under load. And rep 1's calibration
is an outlier at 109 µs against 23 and 27, so that row is the weakest of the three.

**The 2205 µs was the harness verifying inside the credit window.** New receiver instrument
`hold_us` measures from the transform's gate completing to `slot_requeue` returning.
`detect_peaks` runs in that gap, so the slot the NIC could be refilling sits in a peak search
and the sender blocks in `AcquireSendRegion` for exactly that long, then reports it as send
time. `rq_us`, the re-queue call itself, is 1–8 µs and was never a candidate.

| arm | send p50 | hold p50 | gap p50 | MiB/s |
|---|---|---|---|---|
| `stream` (`--verify every`) | 2090.71 | 2488.58 | 2561.85 | 1561 |
| `stream-nv` (`--verify off`) | 340.56 | 11.54 | 812.13 | 4925 |
| `stream` | 2070.10 | 2480.34 | 2553.49 | 1566 |
| `stream-nv` | 331.83 | 12.05 | 776.45 | 5149 |
| `stream` | 2250.71 | 2666.04 | 2743.11 | 1458 |
| `stream-nv` | 345.44 | 13.71 | 820.58 | 4875 |

3/3, no overlap, **3.18x**. 4983 MiB/s against the 5843 Gate 3 measured, so **85 percent of the
link where it had been 27**. `rdma/extbuf_fft_server.cu` already said Phase 4 needed
`--verify off`; `scripts/phase4_cell.sh:193` passed `--verify every`. The two files disagreed
in the repository for a month. The server now refuses the combination rather than trusting the
caller to remember.

**Slot depth is innocent.** `stream-nv` at 2/4/8/16 slots: 4785–5030, 4875–5149, 4986–5017,
4942–5027 MiB/s. One distribution. This was the most attractive of the four candidates because
it would have been a one-line fix with a large effect, and it was wrong.

**The new bound is the sender's CPU.** `gen_p50` 468 µs plus `send_p50` 335 µs is 803 µs of
single-threaded host memcpy against a `gap_p50` of 800 µs. The PXI copies 4 MiB twice per
message, once building the frame and once inside `grpc_direct_client_send`. So the receive path
sustains 85 percent of line rate and the limit is a synthetic sender doing work a real digitizer
would not do. That framing is currently an assertion and the next experiment is to measure it.

**Two side findings from the same audit.** The cuFFT *output* is `cudaMalloc`'d device memory in
all four benchmarks with no device-to-host copy anywhere, so that hypothesis is closed negative.
The cuFFT *input* is not the same across paths: extbuf transforms `cudaHostAlloc(Mapped)` host
memory while gRPC and DAQiri transform device memory after an H2D copy, so `fft_p50` is
confounded across paths. Both DAQiri benchmarks are also single-process loopback while the
extbuf RDMA arm is genuinely cross-machine.

> **Correction, 2026-08-24: the second side finding is scoped too widely as written.** It is true
> of `daqiri/bench_daqiri_pipeline.cc` (the socket path) and of the copy-mode gRPC server. It is
> **not** true of the four arms in the standing Table B. There, `headline_sweep.sh` runs `daq` with
> `--zero-copy` and `opt` with the align probe on, so both transform pinned host memory **in place
> with no copy**, and they agree to 0.9 µs at 4 MiB, which is what makes the memory-class ladder
> credible rather than confounded. Only `base` copies, because `--no-zc-align` forces the realign
> path, and that copy is **D2D into device scratch, not H2D**. See handoff 7n and the corrected
> table in `LONGTERM_CONTEXT.md`.

### Phase 2 — the RDMA data path works, and the checker was validated first (2026-08-20, commit `7a49963`)

The PXI RDMA-writes over RoCE into a `cudaHostAlloc`'d pool on the Spark and cuFFT transforms
those bytes in place. No copy anywhere. Sources: `rdma/rdma_fft_server.cu` (Spark),
`rdma/rdma_fft_client.cc` (PXI), `rdma/rdma_contract.h` (shared). Raw libibverbs with a TCP
side channel rather than `rdma_cm`, because perftest is the only RDMA traffic ever demonstrated
between these two boxes and taking its path means a failure is our bug.

**The broken-ordering control ran before the real implementation, not after.**

| run | sizes | msgs each | verified | failed | CQ errors | timeouts |
|---|---|---|---|---|---|---|
| `--break-ordering` (launch cuFFT *before* observing the completion) | 16, 256, 4096 KB | 20 | **1** | **59** | 0 | 0 |
| correct ordering, full sweep | all nine, 16 KB–4 MB | 200 | **1800** | 0 | 0 | 0 |
| soak | 16, 256, 4096 KB | 10000 | **30000** | 0 | 0 | 0 |

Worst peaks in the broken run were 399902 / 399994 / 400000 Hz against an expected 10000 Hz:
the poison tone, so the failure says *why* rather than merely that something is wrong.

Two design choices are what make that control capable of failing, and both were easy to omit.
The payload tone is a function of the sequence number, so reading the previous message's
leftover bytes fails rather than verifying clean. The slot is poisoned before every message
with a tone no payload uses, so absent data fails as loudly as stale data. Without the first
the test only catches absent data; without the second it only catches stale data.

**One number there is a warning, not a footnote.** At 16 KB, one message in twenty verified
clean *with the ordering deliberately broken*, because a small write can land inside the launch
window. The sensitivity of the ordering test is itself size-dependent. A single-message version
at a small payload would have reported all-clear on a program with the race fully present.

**Hot path asserted, not intended.** Counters freeze after startup; any `cudaHostAlloc`,
`ibv_reg_mr` or `cudaHostGetDevicePointer` afterwards aborts at the call site, and a per-message
assertion re-checks the totals in case something bypassed the wrappers. Every run reported
`1 alloc, 1 reg_mr, 4 translate` at startup and identical at the end. Host VA == device VA
confirmed again at runtime.

This is a lockstep harness with one message in flight. **No timing from it should be quoted.**
Raw output: `data/p2_break.log`, `data/p2_correct.log`, `data/p2_soak.log`.

### Phase 1 — no `cudaHostRegister` flag closes the gap, and the gap is size-dependent (2026-08-19/20, commits `6070ae1`, `dc5eb4a`, `eb83fe9`)

The question was whether the registration penalty is a flag away from disappearing, because if
it were, the whole RDMA transport would be unnecessary. It is not.

4 MB totals, µs, `data/memsrc_flags.csv`:

| arm | how built | total |
|---|---|---|
| `hostalloc` | `cudaHostAlloc`, Mapped | **113.30** |
| `ha_def` | `cudaHostAlloc`, Default | 113.92 |
| `ha_wc` | `cudaHostAlloc`, WriteCombined | 113.46 |
| `ha_wcmap` | `cudaHostAlloc`, WriteCombined+Mapped | 112.99 |
| `shmreg` | `/dev/shm` + `cudaHostRegister`, Mapped | 162.03 |
| `shmreg_def` | `/dev/shm` + `cudaHostRegister`, Default | 165.55 |
| `shmreg_port` | `/dev/shm` + `cudaHostRegister`, Portable | 162.86 |
| `shmreg_big` | `/dev/shm` + `cudaHostRegister`, 64 KB-rounded | 166.43 |

Every allocation arm closes 94–101% of the gap at every size; every registration arm closes
about none of it. Registration arms lose 0/5 at every size ≥ 32 KB. `shmreg_ro` was refused
outright: "operation not supported".

**WriteCombined is not a no-op, it is just not the mechanism.** `/proc/self/smaps` shows the WC
allocation backed by `/dev/nvidiactl` with vmflags `rd wr sh mr mw me ms de dd mm`, against
`/dev/zero (deleted)` with `rd wr sh mr mw me ms` for the plain one. A different driver path
with identical timing, which is a stronger refutation than "the flag did nothing".

**Correction to the headline.** The transform penalty does not exist below about 1 MB. Pooling
nine sizes into one sign test diluted a real 15 µs effect at 4 MB down to p = 1. The 10.94 µs
figure has a domain and every quotation of it now carries "at 4 MB".

**A real bug in the analysis script**, `scripts/memsrc_table.py`: `sign_p` summed only the upper
tail, so an arm losing every one of 45 cells reported p = 1, which reads as "no effect" for the
strongest effect in the table. Now two-sided. Every previously published p-value was for an arm
that won, where both formulas agree, so nothing already written changed.

### All four Phase 6 gates pass (2026-08-19, commits `c91614c` and `c875e0c`)

The design under test: the PXI RDMA-writes over RoCE into a `cudaHostAlloc` + `cudaHostAllocMapped`
buffer on the Spark that was registered with `ibv_reg_mr`, and cuFFT transforms it in place. No
copy anywhere. It is DAQiri's architecture, given to gRPC-Direct without giving up the gRPC API.

| Gate | Result |
|---|---|
| 1 | Host pointer and device pointer are the **same address**, `0x32ee00000`, 2 MB aligned |
| 2 | RoCE ACTIVE both ends, 50 Gb/s, reachable after a temporary IP |
| 3 | 1.81 µs small-message, 5843 MiB/s at 4 MB, **98% of line rate** |
| 4 | `ibv_reg_mr` **accepted** the CUDA-pinned buffer; lkey/rkey `0x00182ae7` |

Three findings beyond the pass/fail:

**Device landing is impossible on this chip, not merely worse.** `GPU_DIRECT_RDMA_SUPPORTED = 0`
and `DMA_BUF_SUPPORTED = 0`, but `HOST_ALLOC_DMA_BUF_SUPPORTED = 1`. Gate 4's control confirmed
it from the other direction: `ibv_reg_mr` on `cudaMalloc`'d memory was rejected with "Bad
address". handoff §7b had ranked GPUDirect RDMA first; that ranking is retired.

**The fabric is not where the time is.** At 98% of line rate there is nothing left to win in the
transport. The 695 µs needed to move 4 MB is paid identically by DAQiri and cancels out of the
comparison. What remains is what happens after the bytes land, which is what this design changes.

**A 5% bandwidth loss was hiding with no error attached.** The PXI came up at netdev MTU 1500,
giving RoCE `active_mtu` 1024 against the Spark's 4096, and a queue pair silently negotiates the
minimum. Measured before and after aligning: 730.29 → 694.76 µs and 5518 → 5843 MiB/s at 4 MB,
with the 2-byte case unchanged as a control. Measuring the baseline first is what made the delta
attributable instead of folded into one number.

### Page size is innocent, `cudaHostRegister` is the mechanism (2026-08-19, commit `f5e5b79`)

This retracts the memory-kind null. That ladder was **read-only**: it never wrote to the
buffer before transforming it, and real pipelines always write first. Dirty the buffer and the
arms separate immediately and stay separated.

4 MB, 15 reps, 200 iterations, arms rotated so no arm keeps a fixed slot:

| arm | how built | write | transform | total |
|---|---|---|---|---|
| `hostalloc` | `cudaHostAlloc` | **56.75** | **53.22** | **109.83** |
| `heapreg` | `malloc` + `cudaHostRegister` | 118.66 | 63.07 | 181.87 |
| `shmreg` | `/dev/shm` + `cudaHostRegister` | 117.49 | 64.19 | 181.57 |
| `hugereg` | verified 2 MB THP + `cudaHostRegister` | 114.53 | 66.91 | 181.65 |

`shmreg` slower than `hostalloc` **15/15, p = 6.104e-05**, by 10.94 µs of GPU time at a 4 MB
payload. `heapreg` and `hugereg` are each 0/15 faster than `hostalloc`. **10.94 µs exceeds the
entire remaining 8.10 µs gap to DAQiri.**

The decision rule was stated before the run: if the huge-page arm matched `hostalloc`, page
size was guilty; if it matched `shmreg`, page size was innocent. It matched `shmreg` to within
0.3 µs. The three slow arms share nothing but `cudaHostRegister` — they differ in page size, in
`MAP_PRIVATE` vs `MAP_SHARED`, and in pre-faulting — and land on top of each other. Both paths
use `...Mapped` plus `cudaHostGetDevicePointer`, so pointer acquisition is not the difference.

A `/proc/self/smaps` audit was added because a name is not evidence. `cudaMallocHost` turns out
to be **4 KB pages** backed by a deleted `/dev/zero`, with vmflags byte-identical to our
`/dev/shm` arm, so there was never a page-size difference to explain. The audit also caught a
defect: the old huge-page arm reported `THP` purely because `madvise(MADV_HUGEPAGE)` returned
0, while holding **zero** huge pages below a 2 MB payload. It now warns when `AnonHugePages`
is 0. `MAP_HUGETLB` is impossible here anyway: `HugePages_Total: 0` and filling the pool needs
root.

Method note: the first version had arms in fixed order and `hostalloc`, listed first, won 15/15
against everything, which is what an order effect looks like. The loop was changed to rotate
the starting arm each iteration, as its comment had already falsely claimed. The effect
survived and grew from 7.17 to 10.94 µs at 4 MB. **Interleaving is not rotating.**

iceoryx2 0.7.0 was checked for an escape hatch and has none: `shm_open` at
`shared_memory.rs:185`, hardcoded `MAP_SHARED` at 588-597, and no reference to `MAP_HUGETLB` or
`MADV_HUGEPAGE` anywhere in the crates. There is no config line, only a dependency patch.

### Registration granularity is not the mechanism (2026-08-18, commit `50ce845`)

`--zc-bigreg` rounds the `cudaHostRegister` span down to a 64 KB boundary and up to a 64 KB
multiple, so we register whole GPU pages exactly the way DAQiri's MR does, over the very same
host memory. Nothing about the data or the plan changes, only the mapping granularity. It was
rejected once before, but that verdict predates the interleaving rule and predates knowing the
cuFFT gap was real, so it earned one careful re-run: 3 arms × 3 reps × 5 sizes, interleaved.

| KB | exact e2e | bigreg e2e | daq e2e | fft gap to daq | share of gap in cuFFT |
|---|---|---|---|---|---|
| 16 | 12.80 | 12.14 | 11.66 | 0.06 | 13 % |
| 256 | 24.64 | 24.37 | 20.78 | 2.40 | 73 % |
| 1024 | 33.15 | 33.38 | 28.30 | 4.10 | 81 % |
| 2048 | 42.94 | 42.59 | 38.26 | 3.20 | 74 % |
| 4096 | 73.07 | 71.70 | 63.36 | 7.42 | 80 % |

**Clean null.** `bigreg fft < exact fft` in 9/15 cells (p = 0.61), e2e 9/15, residual 8/15.
Meanwhile `daq fft < bigreg fft` holds 14/15 (p = 1.2e-04). Page-granular registration leaves
the gap completely untouched.

Correctness ran before timing: top-3 spectral peaks byte-identical between `exact` and `bigreg`
at 16/256/4096 KB. The fallback guard fired on 2 of 3 `bigreg` reps at 4 MB, where the
rounded-down base ran off the front of the mapping and the arm silently degraded to exact-span
registration. Those cells are duplicates of `exact`, not a real arm; the null holds because the
other four sizes are clean and equally flat. Without that guard the run would have read as
"tested and no effect" while two of the fifteen cells were not testing anything.

**Staging-copy arithmetic, recorded so nobody re-proposes it:** copying the payload into
`cudaHostAlloc`'d memory to buy DAQiri's faster FFT costs 4 MB ÷ 52 GB/s ≈ 77 µs to save 6.40 µs.
D2D and H2D both wall at that same ~52 GB/s, so the API choice does not rescue it. Dead at
every size, by a factor of twelve at the size where the prize is largest.

### 54-run headline sweep, and a reversal on where the gap lives (2026-08-18, commit `efe712d`)

9 sizes × 3 arms × 2 reps, arms interleaved within each rep, all rows stamped `952b68a`.
`base` = `--no-zc-align --no-opt-stream`, `opt` = current defaults, `daq` = DAQiri RoCE.

| KB | base | optimized | DAQiri | speedup | gap µs | gap % |
|---|---|---|---|---|---|---|
| 16 | 17.09 | 12.78 | 11.70 | 1.34× | 1.09 | 9.3 % |
| 256 | 27.45 | 23.78 | 20.74 | 1.15× | 3.03 | 14.6 % |
| 1024 | 47.70 | 32.87 | 28.27 | 1.45× | 4.60 | 16.3 % |
| 4096 | 127.02 | 70.41 | 62.31 | **1.80×** | 8.10 | 13.0 % |

Four sign tests at 18/18 cells, p = 7.629e-06 each.

**Retraction A:** the previously reported 2.91 µs gap at 4 MB came from a single un-repeated run
and did not replicate. That run's DAQiri figure was 69.07 vs 62.31 here while gRPC barely moved
(71.98 → 70.41). Interleaving removes bias *between* arms; it says nothing about how much one
measurement *moves*. Two reps minimum, three for a new claim.

**Retraction B, the big one:** "the remaining gap is in the FFT, not the transport" was inverted
at one point to "the transform is not involved." It is involved, and it is most of the problem.
Gap decomposition inside each (size, rep) cell, so the identity stays exact and drift cancels:

| KB | e2e gap | cuFFT gap | residual gap | share in cuFFT |
|---|---|---|---|---|
| 16 | 1.09 | 0.77 | 0.32 | 71 % |
| 256 | 3.03 | 2.27 | 0.77 | 75 % |
| 1024 | 4.60 | 3.82 | 0.77 | 83 % |
| 4096 | 8.10 | 6.40 | 1.70 | 79 % |

**Retraction C:** the "1024/2048 KB cuFFT anomaly" was never size-specific. The cuFFT gap exists
at every size and rises monotonically with payload. The apparent match at 4 MB in the old run
was the artifact, not the anomaly.

**The `n` question, closed.** gRPC arms reported 171–200 received against DAQiri's 250. The
shortfall *shrinks* with size (171.5 at 16 KB, 190.5 at 1 MB, 200.0 at 4 MB), which is the
opposite of drops-under-load. `check_drop_bias.py` over all 18 `opt` files: **18/18 contiguous,
0 holes, 0 skipped.** Every window ends at seq 249, and `minseq` is 50 at 4 MB, exactly the
warmup count. The window is truncated at the **head**, during warmup, because warmup counts
received messages rather than sequence numbers. No published percentile is affected and there
is no survivor bias.

**Both arms run the same transform.** Code read across `bench_grpc_server.cc`,
`bench_daqiri_roce_pipeline.cc` and `cufft_executor.*`: same `cufftPlan1d` R2C, same n, batch 1,
default strides, **out-of-place in both**, no `cufftSetWorkArea` in either, one JIT warmup each,
plan built once. Both write output to `cudaMalloc`'d device memory, so the placement penalty is
**not** paid twice and an input-side A/B will see all of it. The only differences are the stream
and completion method (dedicated non-blocking + `cudaEventQuery` spin vs null stream +
`cudaEventSynchronize`, worth ~0.39 µs and landing in the residual) and the **input memory
source**, which is the live candidate.

**Memory-source ladder, confirmed** (4 MB, paired within cells): `cudaMalloc` device **45.15** <
DAQiri pinned MR **57.36** < iceoryx2 registered shmem **63.76** µs. `opt fft` slower than
`daq fft` in **18/18 cells, p = 7.629e-06**. This closely reproduces the earlier 45.6/58.8/68.8
ladder that had been retracted: the retraction was right about the evidence being cross-run and
wrong about the conclusion. Note `opt` vs `base` is **confounded** (two flags differ), so only
`opt` vs `daq` is a clean placement comparison.

> **Reconciled 2026-08-24, and one line of it no longer holds.** The interleaved Table B run
> (handoff §7n) measures the same ladder at 4 MiB inside a single rotation with a fourth arm
> added: `base` 47.78 from device memory, `daq` 64.13 and `opt` 64.99 from pinned host,
> `extbuf` 78.40 from pinned host. The **shape reproduces**, which is the third independent
> confirmation, and the device-to-pinned step is about 16 µs.
>
> What does not survive is `opt fft` slower than `daq fft`. That was 18/18 with p = 7.629e-06
> at a time when the two arms were sent at different rates. At a matched `PACE=25` they land
> within 0.9 µs of each other, and it is that agreement, two different transports on the same
> memory class, that makes the ladder credible now. The sign test was real; it was measuring
> the pacing difference, not the placement. **Never compare cuFFT times across processes or
> runs**: the same `hostalloc` arm measured 66.1 µs in a 6-arm run and 59.1 µs in a 4-arm run
> minutes later, because the interleave cycle length changes the clock state.
>
> The code read above, which concluded both arms build the same plan, is confirmed against
> source in §7o and extended: same n once the units are checked (both harnesses take samples),
> same output memory, and alignment ruled out by measurement.

### gRPC-Direct latency optimization — E2 alignment fix (2026-08-07)

Branch `grpc-direct-optimization`. All optimizations are opt-in flags so the baseline stays
measurable. Decomposing `e2e − fft_exec` into a "residual" was the key move: DAQiri's residual
is flat at ~4.9 µs across a 256× size range while gRPC's grew 8.1 → 81.5 µs. The entire gap
lived there.

**Root cause:** the server decided whether cuFFT could read the payload in place with a
hard-coded `(dptr & 15) != 0` test. The protobuf backing store is **8-byte** aligned, not 16, so
that test sent **100 % of messages** through a device-to-device "realign" copy. cuFFT actually
accepts the 8-byte pointer, so the copy was never needed. It cost ~77 µs at 4 MB and was
invisible to stage timers because `cudaMemcpyAsync` only enqueues — the cost landed inside the
FFT's `cudaEventSynchronize`.

| Size | before (µs) | after E2 (µs) | speedup | DAQiri RoCE (µs) | remaining gap |
|---|---|---|---|---|---|
| 16 KB | 17.3 | **12.4** | 1.39× | 11.5 | 0.9 |
| 256 KB | 26.6 | **23.8** | 1.12× | 20.9 | 2.8 |
| 4 MB | 127.2 | **75.9** | **1.67×** | 63.7 | 12.2 |

p99 improves at every size too (4 MB: 144.7 → 86.9 µs). Correctness verified: top-3 spectral
peaks identical to the CPU-copy ground truth at all sizes.

**Rejected, with numbers (4 MB p50):** E1 `--zc-h2d` 128.8 (no change, worse p99);
E3 `--zc-kernel` 110.8 (SM copy runs at ~102 GB/s vs the copy engine's 52, still not enough);
E4 `--zc-bigreg` 77.5 (no effect), `--zc-ro` rejected by the driver.

**Latent bug found:** `CMAKE_CUDA_ARCHITECTURES` was 90 (Hopper) but the GB10 is sm_121, so any
custom kernel failed to launch silently. The first E3 run "won" at 53.9 µs with an all-zero
spectrum. Fixed to `native` in both CMakeLists and both build scripts; kernel launches now
check `cudaGetLastError()`.

**Remaining gap is inside the FFT, not the transport.** DAQiri's `cudaHostAlloc`'d MR gives a
58.8 µs FFT; our `cudaHostRegister`'d protobuf heap block gives ~68.8 µs. Scripts:
`scripts/phase0_probe.sh`, `scripts/e12_probe.sh`, `scripts/e34_probe.sh`, `scripts/verify_e2.sh`.

### Two-machine Spark ↔ PXI RoCE link — LIVE & RDMA-VERIFIED (2026-08-06)

The real direct 50 G RoCE link between the DGX Spark and the PXIe-8881 is up and
RDMA works end-to-end (not a single-device loopback).

| End | Interface | RDMA dev | IP | MAC |
|---|---|---|---|---|
| Spark (`spark-ac69`) | `enp1s0f0np0` (LEFT QSFP) | `rocep1s0f0` | `192.168.20.1/24` | `4c:bb:47:2e:ac:6a` |
| PXI (`NI-PXIe-8881-31F6D74`) | `enp117s0` | `rocep117s0` | `192.168.20.2/24` | `b8:ce:f6:40:5e:ea` |

- **What was wrong:** the PXI RoCE port had only a link-local `169.254.x` address, so the
  50 G subnet was dead. Assigning `192.168.20.2/24` to `enp117s0` fixed it.
- **Port identity proven by ARP** (LED-blink needs root, which we lack on Spark): the PXI learned
  `192.168.20.1` at MAC `4c:bb:47:2e:ac:6a` = Spark `enp1s0f0np0` → that is the PXI-facing port.
- **L3 verified:** bidirectional ping 0 % loss (Spark→PXI ~0.09 ms, PXI→Spark ~0.83 ms).
- **RDMA verified:** `rping` server on PXI + client on Spark completed 10/10 RC read/write
  exchanges over RoCE v2, clean disconnect. Full path (rdma_cm, GID/MTU, WRITE/READ) works.
- **Access note:** root available on the PXI (`root@10.198.65.118`, key auth). PXI IP is runtime
  only (`ip addr add`) — not yet persisted (NI Linux RT / connman). Spark side is persistent.
- Scripts: `scripts/pxi_check.sh`, `scripts/pxi_setip.sh`, `scripts/rdma_tools.sh`,
  `scripts/pxi_rping_server.sh`, `scripts/port_map.sh`.

### DAQiri RoCE true zero-copy pipeline + 4 MB sweep (2026-08-05)

RoCE RC transport preserves whole message boundaries (1 work-request = 1 payload, scatter-gather
DMA) so it delivers every payload intact to 4 MB — where the old TCP socket shim fell off a cliff
at ~128 KB. On GB10 (unified NVLink-C2C) the pinned host pointer == device pointer, so zero-copy is
a true in-place cuFFT with 0 µs H→D transfer.

| Size | ZC e2e p50 (µs) | ZC e2e p99 (µs) | Copy e2e p50 (µs) | Drops |
|---|---|---|---|---|
| 16 KB | 11.5 | ~15 | — | 0 |
| 128 KB | 20.4 | — | — | 0 |
| 1 MB | 28.2 | — | — | 0 |
| 4 MB | 63.7 | 75.5 | 167.1 | 0 |

All 18 runs (9 sizes × copy/zerocopy) PASSED, 0 drops every size, 200/200 delivered.
Zero-copy transfer = 0 µs at every size. At 4 MB, e2e(63.7) ≈ fft(58.8) → transport overhead ≈ 0.
Built from `daqiri/bench_daqiri_roce_pipeline.cc` + `daqiri/config_roce_pipeline.yaml`
(single-device RC loopback on `192.168.20.1`, no root). Sweep: `scripts/roce_sweep.sh` →
`data/daqiri_roce_{mode}_{size}.csv`.

### gRPC-Direct 4 MB sweep + RoCE-vs-gRPC comparison (2026-08-05)

Matched params to the RoCE sweep (N=200, W=50, pace 400 µs, shmem). All 18 gRPC runs PASSED to
4 MB. gRPC shmem now scales to 4 MB (unlike the old 128 KB socket cliff) and gets the same ~2.6×
zero-copy speedup, but RoCE is lower latency at every size with a tighter tail.

| Size | RoCE ZC e2e p50 | gRPC ZC e2e p50 | RoCE p99 @4MB | gRPC p99 @4MB |
|---|---|---|---|---|
| 16 KB | 11.5 | 16.9 | | |
| 128 KB | 20.4 | 26.0 | | |
| 1 MB | 28.2 | 47.4 | | |
| 4 MB | 63.7 | 126.3 | 75.5 | 134.4 |

- Gap ~1.5× @16 KB → ~2.0× @4 MB (p50). RoCE p99 much tighter.
- Delivery: RoCE 200/200, 0 drops every size; gRPC shmem closes early at small sizes
  (n_measured 172–175/200 for ≤128 KB, full 200 only ≥1 MB).
- Report: [GRPC_VS_ROCE_4MB.md](GRPC_VS_ROCE_4MB.md). Data: `data/grpc_{mode}_{size}.csv`.

### Pipeline B — transport comparison (matched pace 400 µs, median-of-3 trials, N=1000)

| Buffer | Transport | Wire p50 (µs) | Delivery | Throughput (MB/s) | Server E2E p50 (µs) |
|---|---|---|---|---|---|
| 4096  | standard gRPC | 196.7 | 100 %   | 103.0 | 159.3 |
| 4096  | shmem         | 24.4  | 97.0 %  | 131.0 | 125.1 |
| 8192  | standard gRPC | 147.5 | 100 %   | 228.5 | 143.4 |
| 8192  | shmem         | 24.2  | 97.2 %  | 250.9 | 130.6 |
| 16384 | standard gRPC | 209.0 | 100 %   | 351.3 | 186.9 |
| 16384 | shmem         | 31.0  | 97.1 %  | 470.0 | 139.4 |
| 32768 | standard gRPC | 212.9 | 100 %   | 561.6 | 233.8 |
| 32768 | shmem         | 65.4  | 97.3 %  | 621.8 | 210.8 |

**Headline:** shmem transport is 3–8× lower wire latency (24–65 µs vs 147–213 µs); the
tradeoff is delivery (standard 100 % via backpressure vs shmem ~97 % lossy ring).
**Correction:** H→D copy is byte-identical code and GPU-DVFS-dominated, so it is NOT a
transport discriminator — the earlier "shmem 5× slower" result was a benchmarking artifact.
See [M9_REPORT.md](M9_REPORT.md) for full methodology.

### Pipeline A — DAQiri direct DMA (reference)

| Buffer | E2E p50 (µs) | H→D p50 (µs) | Throughput (MB/s) |
|---|---|---|---|
| 16384 | ~28 | ~12 | ~2200 |

Pipeline A is ~order-of-magnitude faster end-to-end than either Pipeline B transport
(hardware DMA, no serialization/loopback/flow-control). Pipeline B's value is
architectural (network-transparent, decoupled, multi-consumer), not raw latency.

---

## M1 — cuFFT Executor + Validation
**Status:** COMPLETE ✓ (2026-07-13)  
**Files:** `fft/cufft_executor.h`, `fft/cufft_executor.cu`, `fft/fft_validate.cc`, `fft/CMakeLists.txt`

**Results (Spark, GH200, N=16384, fs=1 MHz):**
| Metric | Value |
|---|---|
| Warm-up FFT exec | 35.87 µs |
| Steady-state FFT exec | **9.28 µs** |
| Frequency resolution | 61.0 Hz/bin |
| Detection tolerance | ±30.5 Hz |
| 500 Hz | PASS |
| 1200 Hz | PASS |
| 2500 Hz | PASS |

---

## M2 — Signal Generator + CSV Logger
**Status:** COMPLETE ✓ (2026-07-13)  
**Files:** `common/signal_gen.h/.cc`, `common/metrics.h`, `common/csv_logger.h/.cc`, `common/buffer_pool.h`, `common/CMakeLists.txt`

All components built cleanly on Spark (aarch64, GCC 13.3). `signal_gen` exercised by `fft_validate` (3-tone signal, 16384 samples). CSV logger and buffer pool will be exercised in M5 end-to-end run.

---

## M3 — DAQiri Session Init
**Status:** COMPLETE ✓  
Socket-loopback synthetic buffer injection PASSED: 100 TX, 1,638,400 bytes RX, zero loss.

---

## M4 — DAQiri → CUDA Device Memory
**Status:** COMPLETE ✓  
socket → H→D → cuFFT PASSED all 4 sizes; p50 E2E 22 µs (4K) → 58 µs (32K). Data verified in device memory.

---

## M5 — End-to-End Pipeline A
**Status:** COMPLETE ✓  
Continuous pipeline; per-buffer metrics logged to `data/daqiri_pipeline_<N>.csv`. CPU 2–4 %, GPU util ~0 % (expected for µs bursts).

---

## M6 — Pipeline A Buffer-Size Sweep + Nsight
**Status:** COMPLETE ✓  
Sweep N = {4096, 8192, 16384, 32768}. Nsight kernel times: 2.4 / 3.3 / 5.9 / 9.9 µs; H→D GPU DMA ~1.1 µs. 6 figures (`fig_m6_*`).

---

## M7–M10 — Pipeline B (gRPC Direct)
**Status:** COMPLETE ✓ (M10 profiling PARTIAL — Pipeline B Nsight not re-run; GPU kernels are byte-identical to M6)  
`bench_grpc_server.cc` accepts float32 buffers over both standard gRPC and shmem (gRPC Direct). Pinned staging + CUDA-event H→D. Matched-pace sweep over 4 sizes × 2 transports × 3 trials → `data/mc_*.csv`. Wire-latency metric added.

---

## M11–M13 — Comparison & Report
**Status:** COMPLETE ✓  
Side-by-side data (`data/mc_*.csv` + `scripts/aggregate_matched.py`), figures (`scripts/plot_m9_comparison.py` → `fig_m9_01..06`), and reports [M9_REPORT.md](M9_REPORT.md) + [RESULTS.md](RESULTS.md).
