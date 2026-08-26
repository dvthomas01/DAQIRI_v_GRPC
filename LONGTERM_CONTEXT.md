# Long-Term Context — Architectural Reference
**Project:** DAQiri GPU FFT Pipeline Benchmark  
**Updated:** 2026-08-26  
**Precursor project:** gRPC / gRPC Direct benchmark — all 20 milestones complete 2026-07-08

> **This file is committed now.** It was gitignored while `handoff_roce_2026-08-06.md`,
> `presentation/HANDOFF.md` and `scripts/find_spark.sh` all pointed readers at it.

---

## Key findings (a cadence mistaken for a cost, 2026-08-26)

These come from adding two columns to a comparison, over-reading one of them, and being
challenged on it. The retraction is the transferable part.

- **Know what a number is a number of before you put it in a total.** A new transport column was
  summed into a per-message pipeline total and the arms were ranked on it. The column was not a
  per-message cost, it was a delivery cadence: the receiver idles milliseconds and then takes a
  dozen messages at once. Adding it to a total implies each message pays it, and no message
  does. **Aggregation is a claim about the quantity's meaning, and it is made silently.**
- **A dimensional check catches this for free.** The suspect column was flat while the payload
  grew 256 times. A transport cost cannot be flat in payload. That single observation was
  available before any of the diagnostic work and would have prevented the ranking.
- **When someone challenges a result, investigate instead of defending it.** Three objections
  were raised and all three were right, including one about the topology that had been true and
  unstated for weeks. The cheapest way to find out you are wrong is to take the objection
  seriously enough to test it.
- **A retraction should say what still stands.** The ranking was withdrawn; the receiver-window
  ordering it appeared to contradict was never contradicted at all, and it wins 10 of 10 cells.
  A retraction that does not separate the two leaves readers assuming the whole thing collapsed.
- **Per-message age is ambiguous between at least three mechanisms.** A falling sawtooth in
  message age fits a receiver that is behind, a sender that bursts, and a path that batches
  equally well. Separating them needs inter-arrival gaps *and* a counter of how far the sender
  has already got. One instrument produced a story; two produced a fact.
- **Rule candidates out by experiment even when you are confident.** Four mechanisms were
  eliminated, each by a run rather than an argument: busy-polling instead of sleeping,
  stall rate by third of the run, a sender-progress counter, and a core map. None of the four
  arguments would have been as convincing as the four runs.
- **Publish the loggability verdict alongside the data.** The sweep was correctly instrumented
  and its sampling had three defects, so the numbers went into the repository with an explicit
  do-not-quote note and the list of what would have to change. Data that is silently
  untrustworthy is worse than data that is loudly untrustworthy.
- **A column is only comparable across arms if the same work is visible to the harness in each.**
  The sender-fill column read 0.03 µs for one transport and 5.80 for another, which looks like a
  200x difference and is a difference in where the copy is attributed. One library copies inside
  its send call; the other hands you the registered buffer to write into. Same work, different
  side of the API.
- **Defaults are treatments held at one level, which is the 2026-08-24 lesson with the constant
  moved into the source.** An optimization was already compiled into the receiver, defaulted off,
  and never once passed by a sweep. Every published figure for that arm was taken without it. The
  earlier work had even read the line, and drew the correct but narrower conclusion that both
  arms therefore matched, without asking what happens when it is on. **Ruling out a flag as a
  *difference between* arms is not the same as ruling it out as an *improvement to* both.**
- **When a metric you predicted could not move does move, that is information about your model
  of the instrument.** A device-side event duration was expected to be immune to a host wait
  policy and was not. Clock drift and stream interference were both checked and neither fit. The
  start event is enqueued before the kernel, so host submission latency falls inside the
  device-timed window. The apparent anomaly located a real property of the measurement.

---

## Key findings (measure the noise floor before trusting a gap, 2026-08-25)

These come from two of our own tables disagreeing by 12 µs under identical parameters.

- **Three tight values are not three precise values.** Two tables put the same pair of arms
  0.86 µs and 12.99 µs apart, same sizes, same pacing, same rotation, three reps each. Neither
  was wrong. The single-cell standard deviation at 4 MiB is 4.4 µs and the paired within-rep
  difference has 5.5, so a median of three carries about 4 µs of standard error and the
  difference of two such medians about 5.6. The two results are 2.2 standard errors apart, which
  is ordinary, especially since they were compared *because* one looked extreme.
  **Measure the noise floor once, explicitly, and then you know what your reps buy you.**
- **Three reps establishes a sign, not a magnitude.** Anything a conclusion rests on gets twelve,
  with the arm order rotated through all positions so that arm is not confounded with position.
  The position effect here was 1.50 µs, so the fixed order earlier sweeps used was not the fault,
  but that also had to be measured rather than assumed.
- **When you suspect a rebuild changed something, test the rebuild.** The obvious explanation was
  that adding timers to one binary slowed it. Reconstructing the pre-timer source and building it
  through the same target showed the rebuild inert and the timers free. The obvious explanation
  was wrong and cost one script to eliminate.
- **CUDA event durations cannot tell you whether time is work or waiting; a profiler can.** The
  arm with more event time turned out to have *faster* kernels and more dead space between them,
  28 percent against 16. Nothing that makes memory slower to read can explain that, so an entire
  class of hypotheses died at once. **Ask whether your slow number is more work or more waiting
  before generating explanations for either.**
- **When a contradiction dissolves, the hypothesis invented to reconcile it loses its
  motivation too.** Most of the disagreement was sampling noise, so the elaborate mechanism
  proposed to explain it no longer had anything to explain.

---

## Key findings (an uncontrolled treatment, 2026-08-24)

These come from re-running a published comparison under conditions the original had left free.
The result reversed at two of four sizes. That is the transferable part.

- **A variable you did not choose is still a treatment.** The send pace was hardcoded at 400 µs
  in the harness because that was the value it was written with. One arm degrades by 3x above
  100 µs of pacing and the other does not move, so a table comparing them at 400 was measuring
  the pace, not the transports. Nobody chose to vary it, which is exactly why nobody checked it.
  **Every constant in a comparison harness is a treatment held at one level, and the ones you
  never thought about are the ones held at an arbitrary level.**
- **Two harnesses is a confound even when both are correct.** The retracted table paired numbers
  from two different scripts run five days apart. Both scripts were right. The comparison was
  not. The fix was not to make the scripts agree, it was to put every arm inside one rotation of
  one script in one thermal window.
- **Check the thing the previous writeup told you to check, even when you expect it to be
  nothing.** The instruction was to verify both arms ran the same FFT. They did, which closed
  that door, and the work of checking is what surfaced the pacing cliff. A negative result on the
  named question can still be the cheapest route to the real one.
- **Rule out candidates by measurement even when reading the source already killed them.** One
  of the two candidates for the last open gap was refuted by a single line of source: the flag it
  blamed was never passed. It was tested anyway. A candidate killed by reading is one
  misunderstanding away from coming back.
- **Write up an open number with its candidates ruled out.** Two eliminated candidates and an
  unexplained 14 µs is a better handoff than an unexplained 14 µs with two guesses attached,
  because the next person does not repeat the elimination. Negative results have to be recorded
  or they get re-derived.
- **A rate is bytes over a span, not bytes over a median gap.** `1/median` is a rate only when
  the inter-arrival distribution is unimodal. On a burst-reaped receive path below 4 MiB it is
  bimodal, the median sits in the fast mode, and the derived rate is fiction. Every rate claim in
  the handoff was re-derived under this rule and two were withdrawn.
- **A tie against a shared ceiling is not a result.** Two transports both measured at 5.78 GB/s
  looked like equivalence. Both were pinned by a RoCE MTU misconfigured at 1024, and the same
  file recorded the misconfiguration one clause away from calling the number a hardware ceiling.
  **When two systems agree exactly, check what they have in common before concluding anything
  about what makes them different.**
- **Never compare GPU kernel times across processes.** The same arm measured 66.1 µs in a 6-arm
  run and 59.1 µs in a 4-arm run minutes later, because the interleave cycle length changes the
  clock state. Only within-rotation differences mean anything on this part.
- **A single re-transformed buffer is not a neutral microbenchmark on a coherent part.** Cycling
  across four buffers is 4 to 10 µs *faster* than re-transforming one, because re-writing the
  same buffer keeps the lines dirty in CPU cache and the GPU pays to snoop them. The convenient
  benchmark shape is measuring cache coherence, not the thing under test.

---

## Key findings (a mechanism retracted, 2026-08-21 late)

These come from testing the previous day's own explanation and finding it wrong. That is the
transferable part.

- **A correct fix and a correct explanation are different things, and only one of them is
  usually measured.** Turning verification off was worth 3.18x, three of three, no overlap. The
  reason given for it, that the check held the receive buffer and starved the sender's credit,
  was never tested; it was inferred from an instrument that pointed at it. Moving the check out
  of the credit window dropped that instrument's reading by a factor of 1600 and changed the
  throughput by nothing. **If you cannot state what measurement would distinguish your
  explanation from a competing one, you have a correlation and a story.**
- **Buffering absorbs bursts, not deficits.** Adding slots does nothing when the producer is
  continuous and the consumer is simply slower. The depth sweep was flat for exactly the reason
  the credit-window story was wrong, and the two facts sat side by side unconnected for a day.
  When two results are both negative, check whether they are the same negative.
- **On a single-threaded consumer, where work sits in the loop does not matter; only how much
  there is.** Reordering is only a lever when something else can use the thread.
- **Withhold a number you cannot support instead of printing it with a caveat.** The prior
  month's contamination happened because a rate sat in a log and a warning about it sat in a
  different file. The consumer here now prints no rate at all under the flags that invalidate
  it, along with the two contrasting figures. A number that is not printed cannot be quoted.
- **Instrument the sender's own preparation separately from its send call.** Two host copies of
  the payload per message, one ours and one the library's, accounted for the entire gap between
  the measured rate and line rate. Until they were timed apart, the first was invisible and the
  second was being read as fabric time.
- **A synthetic producer that manufactures its data is not the system you are claiming to
  measure.** Real acquisition hardware DMAs into the buffer it hands to the transport. Removing
  the harness's own copy was not an optimisation, it was a correction, and it moved the result
  from 85 percent of link to line rate.
- **Find the next bottleneck before writing the conclusion.** Both of this session's headline
  claims were superseded within a day by the experiment they themselves suggested.

## Key findings (measuring the transport, 2026-08-21)

Full writeup in `handoff.md` §7i. These are the durable, transferable parts.

- **A pipeline benchmark that starts its clock after arrival is not measuring the pipeline.**
  Every latency figure this project produced before today started after
  `grpc_direct_server_receive_ext()` returned, or after the burst was parsed, or after the RDMA
  completion. That scoping was deliberate and labelled honestly while the question was where the
  GPU's time goes. Nobody revisited it when the question became why the other transport is
  faster. **When the question changes, re-derive what the instrument covers.** One of four
  benchmarks measured the wire, and only because it happened to carry a `send_timestamp_ns`.
- **Two machines with no NTP cannot be differenced.** The PXI's realtime clock is 23.13 seconds
  ahead of the Spark's and neither runs NTP or chrony. Any cross-machine one-way latency taken
  from wall clocks is fiction. The fix is a **round trip on one clock**: sender timestamps, far
  side acks a few bytes, sender timestamps again, and a calibration run with the work removed is
  subtracted paired per rep. This is worth reaching for before trying to synchronise anything.
- **A round-trip instrument serialises the thing it measures, so it gives unloaded latency and
  not throughput.** Those are two numbers from two runs and they must not share a table row.
  State it in the tool's own output rather than in a footnote someone will drop.
- **A correctness check placed inside the credit window becomes the transport number.** The
  receiver's spectral verification ran between the transform's gate and the slot re-queue, so
  the sender blocked in `AcquireSendRegion` for 2.5 ms per buffer and reported it as send time.
  Read as fabric latency for a month. Removing it is worth 3.18x and takes the path from 27 to
  **85 percent of line rate**. **In any pipeline where the consumer owns buffer lifetime,
  instrument gate-to-credit-returned as a first-class column**, because nothing else
  distinguishes "the network is slow" from "we are holding the buffer".
- **Two files disagreed about the same flag for a month and nothing caught it.**
  `rdma/extbuf_fft_server.cu` said Phase 4 must run with `--verify off`; `phase4_cell.sh` passed
  `--verify every`. A comment cannot enforce anything. The program now refuses the combination.
  **If a configuration invalidates a measurement, make the binary reject it, not document it.**
- **The most attractive hypothesis was the wrong one, and closing it by measurement was cheap.**
  Slot depth would have been a one-line fix with a large effect. 2, 4, 8 and 16 slots are one
  distribution, 4785 to 5149 MiB/s. Attractiveness is not evidence.
- **Find the new bottleneck before celebrating the old one.** After the fix, `gen_p50` 468 µs
  plus `send_p50` 335 µs is 803 µs of single-threaded host memcpy against an 800 µs arrival
  interval, so the sender's own CPU is now the entire limit. It copies 4 MiB twice per message,
  once building the frame and once inside the library's send. The honest framing is that the
  receive path sustains 85 percent of line rate and the limit is a synthetic sender doing work a
  real digitizer would not do, and that framing is an assertion until it is measured.

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

- **Never quote the first run after a Spark reboot.** Phase 3 step 5 measured `fft` p50 at
  21.25 us and end-to-end p50 at 38.61 us on a freshly booted machine, then 7.62 us and 12.66 us
  on the very next run with nothing changed. `nvidia-smi` explained it: `clocks.sm` was 208 MHz
  against a maximum of 3003 MHz, because the GPU parks at idle clocks and only ramps under
  sustained load. A factor of three, from the machine alone. Both halves of the decomposition
  inflated together, which is the signature to look for: a transport regression moves the
  residual and leaves the transform alone. Query `clocks.sm` alongside every run and discard
  anything taken below roughly 2400 MHz.
- **Sample the clock during the run, not before or after it, and take the peak.** The first
  attempt at the gate above read `clocks.sm` between runs and reported 208 MHz every single time,
  including immediately after a run that was demonstrably fine. Sampling once a second across one
  cell gave `208 208 208 2405 2405 2405 2405 2457 2405 234 208 208`. The part ramps about three
  seconds into sustained load and falls back to idle within one second of the load stopping, so a
  reading taken between runs measures the gap, not the work. The peak is the right statistic
  rather than the mean, because the sampling window contains startup that is idle by
  construction and averaging it in gates out healthy cells. This also sets a floor on run
  length: a cell that finishes in under three seconds never ramps at all, which is exactly what
  happened to the 500-message Phase 3 runs, so the RDMA arms need enough unmeasured traffic
  ahead of the measured section to get the clock up first.
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
- PXI IP is runtime-only. **The PXI's `192.168.20.2/24` does not survive a *Spark* power cycle,
  not only a PXI reboot.** The PXI had 13 days uptime when it lost the address, and had not
  rebooted; the carrier flapped when the Spark went down, and the address went with it. What
  remained was a `169.254/16` link-local address, while `mtu 9000` survived. Recovery is
  `scripts/roce_restore_pxi.sh` (root on PXI), which is `ip addr add 192.168.20.2/24 dev
  enp117s0` plus the MTU, and then re-reads the GID indices. To persist: NI MAX or `connmanctl`.
  **Check this after every Spark reboot, not just after a PXI reboot**, because the failure is
  silent: the link stays UP, the ibverbs port stays ACTIVE, and only the route is gone.
- **The RoCE GID index follows the address, so it moves when the address changes. Read it
  rather than hardcoding it.** `rdma/rdma_fft_client.cc` defaulted to 5 and the index was
  observed at 3. Fixed 2026-08-20: both endpoints now default to `gid_index = -1`, meaning
  `rdma::find_roce_v2_ipv4_gid()` in `rdma/rdma_link.h` reads the table at startup. `--gid`
  still overrides. Measured tables, which show why the naive search is wrong twice over:

  | | PXI `rocep117s0` | Spark `rocep1s0f0` |
  |---|---|---|
  | 0 | IB/RoCE v1 `fe80::…5eea` | IB/RoCE v1 `fe80::…ac6a` |
  | 1 | RoCE v2 `fe80::…5eea` | RoCE v2 `fe80::…ac6a` |
  | 2 | IB/RoCE v1 `::ffff:169.254.71.218` | IB/RoCE v1 `::ffff:192.168.20.1` |
  | 3 | RoCE v2 `::ffff:169.254.71.218` | **RoCE v2 `::ffff:192.168.20.1`** ← Spark uses this |
  | 4 | IB/RoCE v1 `::ffff:192.168.20.2` | — |
  | 5 | **RoCE v2 `::ffff:192.168.20.2`** ← PXI uses this | — |

  Two traps, both of which the first implementation of the search fell into. (a) Every IPv4
  address appears **twice**, once as `IB/RoCE v1` and once as `RoCE v2`, at adjacent indices, so
  matching on the address alone picks the v1 entry and it will not talk to a v2 peer. (b) The
  PXI carries the link-local `169.254.x` **and** the fabric address, and the link-local sorts
  *first*, so "the first RoCE v2 IPv4 GID" selects index 3, which is the wrong subnet. Selection
  is therefore by peer address: each side asks for the local GID on the peer's `/24`. Verified
  end to end 2026-08-20 with no `--gid` on either side, Spark picking 3 and PXI picking 5,
  20/20 messages verified, 0 failures. `rdma/gid_probe.cc` reproduces the tables above.
- (Historical: an earlier 192.168.10.x link on the 1G ports is obsolete after a room move.)
- easyrdma built on BOTH arches (`core/` subdir only: `cmake .. -DCMAKE_BUILD_TYPE=Release; make`)
- grpc-direct rebuilt with `--features rdma` on BOTH machines
- **Hardware ceiling: SUPERSEDED.** This file used to record 5.785 GB/s = 92.6% of 50G line
  rate, and stated its own cause in the same breath: a 1024-byte IB MTU. That MTU was a
  misconfiguration, found and fixed on 2026-08-19. The PXI boots at a 1500-byte Ethernet MTU,
  which negotiates a 1024-byte RoCE MTU against the Spark's 4096, and a QP silently takes the
  minimum with no error anywhere. Corrected ceiling, `ib_write_bw` PXI to Spark at 4 MB:
  **5843.23 MiB/s = 6.127 GB/s = 98.0% of the 6.25 GB/s line rate** (handoff Gate 3, 7p).
  The control that makes this attributable is the 2-byte case, which fits in one packet either
  way and did not move: 1.81 vs 1.82 us.
  Persist the fix with `ip link set dev enp117s0 mtu 9000` on the PXI; it dies on a reboot
  **and** on a Spark carrier flap.

---

## Prior Benchmark — Key Results (gRPC Direct, complete 2026-07-08)

| Scenario | Transport | Result |
|---|---|---|
| Localhost Echo (C++ interceptor) | grpc-direct shmem | **3.3 µs p50** (281× faster than std gRPC) |
| Localhost Echo (native Rust floor) | grpc-direct shmem | 2.78 µs p50 |
| Streaming throughput zero-copy | grpc-direct shmem | 23.59 GB/s (construction unrecorded) |
| RDMA Echo (machine-to-machine) | grpc-direct RDMA | **36.8 µs p50** (29× faster than TCP) |
| RDMA throughput vs line rate | grpc-direct RDMA | 5.775 GB/s, **at the MTU-1024 ceiling** |
| ~~DAQiri RDMA loopback (Spark)~~ | ~~DAQiri RDMA~~ | ~~5.785 GB/s~~ **RETRACTED** |
| ~~grpc-direct RDMA vs DAQiri~~ | ~~both~~ | ~~< 1% delta~~ **RETRACTED** |
| Standard gRPC TCP baseline | TCP | 929–1086 µs Echo p50, 1.78 GB/s streaming |

**Why the last two rows are struck out (2026-08-24).** 5.785 GB/s is 5518 MiB/s. Gate 3 later
measured this fabric at 5518.37 MiB/s with the MTU misconfigured at 1024. Both arms were
resting on the same wall, and the wall was a bug rather than the hardware, so agreeing to
within 1% says nothing about either transport. Neither figure's construction was recorded and
neither has surviving per-message data, so they cannot be recovered by reanalysis. The claim
that replaces them needs no DAQiri number: **on a correctly configured fabric gRPC-Direct RDMA
runs at 98.0% of line rate.** The 23.59 and 1.78 GB/s figures are not affected by the link
ceiling, but their construction is equally unrecorded; rerun before leaning on them.
See handoff 7p for the full audit of every rate claim in the project.

---

## The standing head-to-head (interleaved, 2026-08-24)

This replaces every earlier extbuf-against-DAQiri table in this project, all of which paired
arms from different scripts or different days. Here all four arms rotate inside one run of
`scripts/headline_sweep.sh`, in one thermal window, at one message rate: `REPS=3`, 1000 measured
messages after 500 warmup, `PACE=25`, `sm_mhz` gated at 2400. Post-arrival processing latency,
e2e medians in microseconds. Both extbuf and DAQiri are loopback on the Spark, so nothing here
crosses a machine boundary and none of it may be compared to a cross-machine number.

| KB | base | opt | daq | extbuf |
|---|---|---|---|---|
| 16 | 15.744 | 11.376 | **9.456** | 10.736 |
| 256 | 26.448 | 22.944 | **18.224** | 20.816 |
| 1024 | 46.752 | 33.712 | **25.072** | 30.432 |
| 4096 | 129.745 | 71.504 | **68.976** | 94.144 |

**DAQiri is faster at every size.** The earlier "crossover", extbuf ahead at the two small sizes
and behind at the two large ones, was an artefact of comparing an unpaced arm against a 400 µs
paced one. At 16 and 256 KB the residuals agree within 0.42 µs, so the whole gap at those sizes
is transform time rather than transport.

The 4 MiB cuFFT terms are the memory-class ladder, measured in the same rotation: `base` 47.78
reading from device memory, `daq` 64.13 and `opt` 64.99 reading in place from pinned host memory,
`extbuf` 78.40 also from pinned host. `opt` and `daq` agreeing to 0.9 µs is what makes the ladder
credible. **Zero copy costs about 16 µs at 4 MiB against a device-resident transform**, and that is
the architectural price, paid knowingly. Extbuf's further 14 µs is unexplained; both named
candidates, stream mode and slot geometry, were tested and ruled out (handoff 7q), which locates it
in the live pipeline rather than the memory layout.

> **Which arms copy, stated because two sections of handoff.md disagreed about it (corrected
> 2026-08-24).** `headline_sweep.sh` runs `daq` with `--zero-copy` and `opt` with `--zero-copy` and
> no `--no-zc-align`, so **both transform pinned host memory in place and neither copies**. Only
> `base` copies, because `--no-zc-align` forces the realign path, and **that copy is D2D**, from the
> mapped shmem buffer into device scratch, **not H2D**. This paragraph previously said `base` read
> device memory "after an H2D copy", which is wrong. `handoff.md` 7i also says the gRPC and DAQiri
> paths transform device memory after an H2D copy; that sentence describes a different pair of
> benchmarks and does not describe this table. `base` transforming 16 µs faster than `opt` and `daq`
> is exactly the point: it is device-resident *because* it paid a 77 µs copy to get there.

Caveat on one cell: the 16 KB `daq` figure rests on a single rep, the other two having tripped
the clock gate at 2379 and 1560 MHz. Their raw values, 9.408 and 9.344, agree with the kept
9.456, so the gate most likely fired on a sampler artefact rather than a real downclock.

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

### Three different comparisons, and which one answers which question

This section has been misread once, so the pairings come first. Three comparisons were run and
they do not measure the same thing:

| # | Left | Right | Result | Answers |
|---|---|---|---|---|
| A | PXI `/home/admin/grpc-direct` | upstream `ni/grpc-direct` @ `2d404a5` | 125 of 127 identical, `src/lib.rs` +529/-31 | what the PXI runs |
| B | Spark `~/grpc-direct` | PXI `/home/admin/grpc-direct` | 144 identical, 2 different, 8 Spark-only | whether the two boxes match |
| C | Spark `~/grpc-direct` | upstream `2d404a5` | **15 files, +1508/-39** | what the benchmarks were built from |

**"144 identical" is comparison B and says nothing about upstream.** It is Spark against PXI. It
looks reassuring and is not, because the two trees agree on 144 files that are *both* forked.
Comparison C is the one that describes the benchmarked library, it was run last, and it is
larger than A and B together suggested.

Comparison C is now reproducible without hashing anything: it is `git diff 2d404a5 daqiri-extbuf`
in the fork.

### Comparison A: the PXI's copy against upstream

Audited 2026-08-20. `/home/admin/grpc-direct` on the PXI has no `.git`, so provenance was
established by hashing every file against a fresh clone of `https://github.com/ni/grpc-direct.git`.
Base is upstream HEAD `2d404a5` (2026-06-11); **125 of 127 tracked files are byte-identical**.
This is the PXI, which sends. It is not the machine the gRPC numbers were measured on.
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

### Comparison B: the Spark against the PXI

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

### Comparison C: the Spark against upstream, which is the one that matters

Run 2026-08-20 once the Spark's tree was committed as branch `daqiri-extbuf` off `2d404a5`.
Fifteen files, +1508/-39 at the measured state (commit `5dfeaa5`):

```
.cargo/config.toml                                |   2 +
cpp/client_interceptor.cc                         |  21 +-
examples/bench_client.rs                          | 225 ++
examples/native_bench.rs                          | 481 ++
plugin/cmd/protoc-gen-grpc-direct/gen_cpp.go      |   4 +-
python/README.md                                  | 245 ++
python/{ => grpc_direct}/*.py                     |   6 files renamed, 0 content change
python/pyproject.toml                             |   2 +-
src/lib.rs                                        | 560 ++
```

**Comparisons A and B missed three of these, and the reason is worth keeping.** The two earlier
probes reported `cpp/client_interceptor.cc` and `gen_cpp.go` and nothing else of substance.
They missed the `python/` package restructure and the two `examples/` additions because
*comparison B was Spark against PXI and both trees already carried them*, so they hashed equal;
and comparison A ran against a file list rather than a commit, so a directory rename read as
absence rather than as a move. A file-by-file hash comparison cannot see a change that both
sides share, and that is the whole failure mode: B's headline number was 144 agreements between
two copies of the same fork.

None of the three additions touch the benchmark path. `examples/` is not built by our CMake,
and `python/` is not linked. They are recorded so the fork's contents are stated once and
correctly, not because they change a number. The two that do matter are still
`cpp/client_interceptor.cc`, which is linked and is inert for our RPC type, and `gen_cpp.go`,
which upstream cannot compile without.

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
