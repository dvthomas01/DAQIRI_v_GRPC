# Matching a purpose-built DAQ transport without giving up the gRPC API

A narrative account of the GPU FFT pipeline comparison between gRPC-Direct and NVIDIA DAQiri.

Reconstructed from `handoff.md`, `PROGRESS.md`, `SHORTTERM_CONTEXT.md`, `LONGTERM_CONTEXT.md`
and the committed CSVs in `data/`. Where a source claim has been superseded, only the surviving
version appears here. Where two sources disagree, or where a number the story needs is thinner
than it looks, there is a bracketed note saying so rather than a smoothed-over sentence.

---

## 1. The goal, and where we started

The system under test is a data acquisition pipeline. A producer generates a block of 32-bit
floating point samples, a transport carries that block to a machine with a GPU, and the GPU runs
a fast Fourier transform on it to turn the time-domain waveform into a frequency spectrum. In a
real instrument the producer is a digitizer card sampling a physical signal, and the reason to
put a GPU at the far end is that spectral analysis at high sample rates is more work than a CPU
can do in the time available. The benchmark stands in for the digitizer with a signal generator
that plants tones at known frequencies, so the receiver can check that the spectrum it computed
contains the tones it was supposed to contain. Correctness is checkable at every step, which
turns out to matter more than it sounds.

Two transports were compared.

**DAQiri** is NVIDIA's purpose-built framework for exactly this job. It uses RDMA, remote direct
memory access, which lets a network card write into a remote machine's memory without either
machine's CPU being involved in the copy. DAQiri allocates its own receive buffers, registers
them with the network card once at startup, and hands the GPU a pointer to the bytes the card
just wrote. Nothing is copied after arrival.

**gRPC-Direct** is National Instruments' low-latency extension to gRPC. gRPC is the general
purpose remote procedure call framework, and its ordinary implementation serialises a message,
pushes it through TCP, and deserialises it at the other end. gRPC-Direct keeps that programming
interface and swaps the plumbing underneath for a shared-memory ring or an RDMA link, so an
application written against gRPC gets a much shorter path without being rewritten.

The project's question was whether gRPC-Direct could match DAQiri. That framing matters. The
prize was never "be the fastest possible thing"; a hand-written RDMA loop would win that and
would also mean every application has to be rewritten around it. The prize was DAQiri-class
numbers behind an interface teams already use. Three rules were set at the start and held
throughout: keep the gRPC API structurally intact, put every optimization behind a flag so the
unoptimized baseline stays measurable, and verify the spectrum before believing any speedup.

The starting position was bad. On the same GPU, at a 4 MB payload, gRPC-Direct's post-arrival
processing latency was roughly twice DAQiri's.

> [Source note: `handoff.md` section 0 states "1.76x slower than DAQiri at 4 MB". The committed
> headline sweep, `data/headline_runs.csv`, gives the unoptimized arm at 127.02 us against
> DAQiri's 62.31 us, a ratio of 2.04x. The 1.76x is not derivable from any committed data file I
> can find, and probably predates the interleaved sweep. I use the committed 2.04x.]

## 2. The first comparison, and the move that made it useful

The first measurements said gRPC-Direct was slower and got worse as the payload grew. That on its
own is nearly useless, because "slower" does not tell you where to look. The move that made the
project tractable was a decomposition.

Every run reports two numbers: end-to-end latency, from the moment the buffer is in hand to the
moment the transform is finished, and the cuFFT execution time, measured on the GPU with CUDA
events. Subtract the second from the first and call the difference the **residual**. The residual
is everything that is not the transform: the bookkeeping, the pointer handling, the event
synchronisation, and any copying the pipeline does on the way.

Splitting the two apart immediately localised the problem.

| payload | DAQiri residual (us) | gRPC-Direct residual (us) |
|---|---|---|
| 16 KB | 4.93 | 8.11 |
| 256 KB | 4.99 | 12.96 |
| 1 MB | 4.83 | 25.90 |
| 4 MB | 4.93 | 81.46 |

DAQiri's residual is flat at about 4.9 us across a 256-fold range of payload sizes. That is what a
fixed cost looks like: recording a CUDA event, synchronising on it, reading a clock. It cannot
depend on how many bytes arrived, because none of those operations touch the bytes.

gRPC-Direct's residual grew with the payload, reaching 81.46 us at 4 MB. A cost that scales with
byte count is a cost that is touching every byte. And at 4 MB the residual gap of 76.5 us was
*larger than the entire end-to-end gap* of 62.6 us, which means the transform side was actually
running slightly in our favour and the whole problem lived in the residual.

So the question became specific: what is touching all four megabytes?

The first hypothesis was that the receiver was re-pinning the payload buffer for every message.
Pinning, or page-locking, is what lets the GPU read host memory directly, and doing it per message
would be expensive. Instrumentation killed the idea in one run: `cudaHostRegister` was called
**once**, with 249 cache hits, at 0.048 us. That is a hypothesis dying cheaply, which is the best
outcome a cheap hypothesis can have.

## 3. The root cause, and why it was invisible

The receiver decides, per message, whether cuFFT can read the arriving buffer where it lies or
whether the bytes must first be copied somewhere better aligned. The decision was one line:

```cpp
const bool needs_realign = (reinterpret_cast<uintptr_t>(dptr) & 15) != 0;
```

That tests whether the pointer is a multiple of 16. The code assumed protobuf's
`RepeatedField<float>` backing store, the buffer a decoded gRPC message hands you, is 16-byte
aligned. **It is 8-byte aligned.** So the test was true for every message ever received, and
100 percent of buffers took a device-to-device copy into scratch memory before being transformed.

Two things make this the interesting kind of bug rather than a typo.

The first is that the copy was never necessary at all. cuFFT accepts the 8-byte pointer. The code
was paying for a workaround to a restriction that did not exist, on the strength of an assumption
nobody had checked against the library's actual requirement. At 4 MB the copy cost about 77 us,
which is most of the residual and therefore most of the gap.

The second is why it hid for so long. A stage timer wrapped around the copy read 3.5 to 5.2 us, so
the copy looked cheap and was dismissed early. The reason is that `cudaMemcpyAsync` does not perform
the copy, it enqueues it: the function returns almost immediately and the GPU does the work later.
The real cost surfaced when the code eventually waited for the transform to finish, inside
`cudaEventSynchronize`, and was therefore billed to the FFT rather than to the copy. Comparing the
FFT's wall-clock duration against its GPU-event duration is what exposed it, because those two
quantities should agree and did not. At 4 MB the wall time was 121.94 us against a 44.93 us event,
a difference of **77.01 us** against a residual gap of **76.53 us**. Those are the same 77 us of
copying seen from two directions, and that correspondence is what turned a suspicion into an
attribution.

Fixing it meant replacing the hard-coded constant with a runtime probe: ask cuFFT what alignment it
actually wants, then decide. At 4 MB end-to-end latency went from 127.2 us to 75.9 us, a 1.67x
improvement, with the 99th percentile improving from 144.7 to 86.9 us as well. The spectrum was
verified identical to a known-good CPU reference at every size before the speedup was believed.

A second, much smaller optimization was adopted alongside it: giving the transform its own
non-blocking CUDA stream and polling for completion rather than blocking. Worth 0.15 to 0.39 us,
far inside the run-to-run noise, but it won 9 of 9 paired comparisons. When magnitudes are noisy and
the ordering is stable, the count of wins is the defensible statistic and the median difference is
not.

**Four other optimizations were tried and rejected, and the rejections are part of the result.**
Doing the realignment as a host-to-device copy instead of device-to-device changed nothing, because
both hit the same 52 GB/s copy-engine wall; the API choice was never the limit. A custom GPU kernel
ran the copy at about 102 GB/s, genuinely double the copy engine, and still lost, because it needed
roughly 170 GB/s to pay for itself. Registering memory in whole 64 KB pages the way DAQiri does had
no effect, twice, under two different measurement disciplines. And `cudaHostRegisterReadOnly`, which
looked promising on paper, is refused outright by the GB10 driver.

One infrastructure bug found here is worth carrying forward. The build was configured for `sm_90`,
the compute capability of Hopper GPUs, while the GB10 in this machine is `sm_121`, so every custom
kernel failed to launch silently, and cuFFT masked it because cuFFT ships its own compiled code. The
first custom-kernel run "won" at 53.9 us while producing an all-zero spectrum. The correctness check
is the only reason that did not become a published number.

## 4. Localizing what was left, and why the work changed direction

After the fix, the picture had to be rebuilt, because the old measurements were no longer
describing the current code. The rebuild was a 54-run sweep: nine payload sizes, three arms, two
repetitions, with the arms run adjacently at each size so that any thermal drift hit all three
roughly equally. The three arms were `base` (gRPC-Direct with both optimizations disabled), `opt`
(gRPC-Direct with them on), and `daq` (DAQiri).

At 4 MB: base 127.02 us, optimized 70.41 us, DAQiri 62.31 us. A **1.80x speedup** from the
alignment fix and the stream, and a remaining gap of **8.10 us, about 13 percent**. Paired sign
tests over all 18 cells came out 18 of 18 in both directions, at p = 7.6e-06: the optimization
beats the baseline everywhere, and DAQiri still beats the optimized build everywhere. Both
statements are solid and neither is close to the noise.

> [Source note: with only two repetitions, the "median" quoted throughout for this sweep is the
> mean of two values. The sign tests are over all 18 size-by-rep cells and are unaffected, but the
> point estimates rest on two samples each.]

Then the same decomposition was applied to the remaining gap, differencing inside each
size-and-repetition cell before taking any median so that the identity stays exact and drift
cancels:

| payload | e2e gap | cuFFT gap | residual gap | share inside cuFFT |
|---|---|---|---|---|
| 16 KB | 1.09 | 0.77 | 0.32 | 71% |
| 256 KB | 3.03 | 2.27 | 0.77 | 75% |
| 1 MB | 4.60 | 3.82 | 0.77 | 83% |
| 4 MB | 8.10 | 6.40 | 1.70 | 79% |

**This reversed the project's direction.** The residual, the part we own and had just spent weeks
fixing, was down to 0.3 to 1.7 us. Roughly 80 percent of what remained was inside cuFFT itself:
the same transform, at the same size, on the same GPU, in the same minutes, running consistently
slower in one process than the other.

That is a strange result, and the shape of it is the clue. Launch overhead is a fixed cost and
would not grow with payload. This grew monotonically, 0.77 us at 16 KB to 6.40 us at 4 MB. A cost
that scales with bytes inside a transform is a memory bandwidth symptom, which points at where the
input buffer lives rather than at anything the transform is doing differently.

So the investigation moved from the transport to memory placement. That transition is the hinge of
the whole project: everything before it was about removing work the pipeline was doing, and
everything after it was about where the bytes sit when the GPU reads them.

## 5. Memory placement, and the correction that is the actual finding

The two paths differ in exactly one relevant way. DAQiri calls `cudaMallocHost`, so the CUDA driver
allocates the pinned buffer. gRPC-Direct receives a shared-memory buffer allocated by the Rust
runtime through iceoryx2, in `/dev/shm`, and calls `cudaHostRegister` on it after the fact. Same
class of memory by any obvious description, two different ways of getting there.

A standalone benchmark was built to test this with no gRPC and no network involved: the same cuFFT
plan run over each kind of memory, arms interleaved, repeated, sign-tested. The first version
declared memory kind irrelevant. **That null was wrong, and finding out why produced the
mechanism.** The ladder only ever *read* the buffer, transforming the same bytes thousands of times
without anything writing to them first. Real pipelines always write first, because something has to
put the data there. Adding a producer write before each transform separated the arms immediately:

| arm | how it was built | write (us) | transform (us) |
|---|---|---|---|
| `hostalloc` | `cudaHostAlloc` | **56.75** | **53.22** |
| `heapreg` | `malloc` + `cudaHostRegister` | 118.66 | 63.07 |
| `shmreg` | `/dev/shm` + `cudaHostRegister` | 117.49 | 64.19 |
| `hugereg` | verified 2 MB huge pages + `cudaHostRegister` | 114.53 | 66.91 |

Driver-allocated memory was faster on both halves: about 2x on the CPU write and 10.94 us on the
GPU transform at 4 MB, 15 of 15 repetitions, p = 6.104e-05. The three slow arms have nothing in
common except `cudaHostRegister`. They differ in page size, in whether the mapping is private or
shared, and in whether it was pre-faulted, and they land within 0.3 us of each other. The huge-page
arm was included as a decision rule declared before the run: matching the fast arm would indict
page size, matching the slow arms would exonerate it. It matched the slow arms.

This looked like the answer. The penalty at 4 MB was larger than the entire 8.10 us gap, and it
justified a substantial piece of engineering: to get the fast kind of memory we would have to own
the receive buffer allocation, which means owning the transport. Two cheap escape routes were tried
first and both failed. No allocation or registration flag closes the gap, across nine sizes and five
repetitions: allocation-side variants recover 94 to 101 percent of the difference, registration-side
variants essentially none.

**Then the finding was overturned in the most useful possible way.** When the two buffer
provenances were measured head to head *inside the real RDMA receiver* at 4 MB, they were
indistinguishable: paired differences of +0.87, +5.07, -3.36, +2.53 and -1.82 us across five
repetitions, three of five in one direction, sign test p = 1.0. A prediction of 10.94 us against a
measurement of nothing is not a discrepancy to be explained away.

So the harness was rerun with the producer's CPU write crossed against the memory kind instead of
held fixed. At 4 MB, with the CPU write, `cudaHostAlloc` transforms 7.31 us faster than registered
memory; without the CPU write, it transforms 11.25 us **slower**. Five of five in both directions,
with under a microsecond of spread inside each arm. **The sign inverts.**

The penalty is therefore not a property of the memory at all. It is a property of the interaction
between the producer's stores and the transform's reads, and `cudaHostRegister` changes that
interaction. The clue had been sitting in the original table and was not followed: registration has
no business affecting *CPU store* speed, and it roughly doubles it, which means it is changing the
page's cacheability or coherency attributes. The transform penalty is the other end of the same
change.

**What this means for the project is the interesting part, and it is a scoping statement rather than
an error.** The effect is real on the shared-memory path, where a CPU producer genuinely does write
every buffer. It does not transfer to an RDMA receiver, where a network card writes the buffer by
DMA and the CPU never touches it. Both measurements were correct about the configuration they
measured. The mistake was carrying one of them into a configuration it had not measured, which is
harder to catch than a bad measurement.

The honest consequence was that the RDMA transport work lost its original microsecond justification
part-way through. It continued on grounds that never depended on it: no per-buffer registration, no
unregistration at teardown, a fixed slot pool, and a release-before-completion gate under our
control. Those are correctness and steady-state arguments, and they should not be dressed up as a
latency argument.

## 6. What the hardware allows, and what got built

Running in parallel with the placement work was a more ambitious idea: stop reading the transform's
input from host memory at all and have the data arrive directly in GPU memory. This is GPUDirect
RDMA, and on paper it is the architecturally correct answer, because the producer is a DMA engine
that has to write the bytes somewhere regardless, so choosing GPU memory as the destination should
be free. Four pre-flight gates were run before any of it was built, and two settled the question.

**The hardware does not offer it.** The capability probe returned `GPU_DIRECT_RDMA_SUPPORTED = 0`
and `DMA_BUF_SUPPORTED = 0`, but `HOST_ALLOC_DMA_BUF_SUPPORTED = 1`. Third-party DMA into device
memory is unsupported on GB10; third-party DMA into page-locked host memory is supported. A separate
probe confirmed it from the opposite direction: the CPU cannot even store into `cudaMalloc`'d memory
on this part, faulting at every size under a guarded one-byte write.

**And the network card agrees.** `ibv_reg_mr`, the call that registers a memory region with the
card, succeeded on a 4 MB `cudaHostAlloc` buffer. The control in the same program attempted the
identical registration on device memory and was rejected with "Bad address". That pairing is worth
more than the positive result alone, because it upgrades "we chose host memory" into "host memory is
the only option this hardware offers".

There is a consolation in the architecture. GB10 is a Grace-Blackwell part with a coherent
CPU-to-GPU interconnect, and on it the host pointer returned by `cudaHostAlloc` and the device
pointer returned by `cudaHostGetDevicePointer` are **the same address**, `0x32ee00000`. Host memory
is not a staging area on this chip, it is memory the GPU reads natively. Landing in host memory is
not second best, it is the design.

The fabric itself was measured and found blameless, and that measurement contains one of the two
corrections worth reading in full. Between the two machines is a 50 Gb/s RoCE link, RDMA over
Converged Ethernet. At 50 Gb/s the theoretical ceiling is 6.25 GB/s, so moving 4 MB takes at least
671 us no matter what. The link measured 5843.23 MiB/s, which is 6.127 GB/s, or **98.0 percent of
line rate**. There is essentially nothing left to win in the wire, and every microsecond still on
the table is in what happens after the bytes land.

**The correction.** That 98.0 percent is not what the fabric first measured, and the difference
propagated into a claim that reached a slide deck. The PXI controller boots with a 1500-byte
Ethernet MTU, which negotiates a 1024-byte RoCE MTU against the Spark's 4096. A queue pair silently
takes the minimum. Nothing errors, no log line appears, and about 5 percent of the bandwidth is
quietly gone. Measured before and after aligning the MTU, with a 2-byte message as a control that
could not possibly be affected and did not move:

| measurement | MTU 1024 | MTU 4096 |
|---|---|---|
| 2 byte write (control) | 1.81 us | 1.82 us |
| 4 MB write | 730.29 us | 694.76 us |
| 4 MB bandwidth | 5518.37 MiB/s | 5843.23 MiB/s |

Earlier project material reported gRPC-Direct RDMA at 5.775 GB/s and DAQiri at 5.785 GB/s and
called it a tie, a sub-1-percent difference presented as evidence the two transports perform
alike. **5.785 GB/s is 5518 MiB/s**, which is the misconfigured-MTU row of that table to three
significant figures. Both arms were resting on the same wall, and the wall was a bug rather than
the hardware. Two systems agreeing exactly is not evidence about what makes them different until
you have checked what they have in common. The tie is withdrawn, and the claim that replaces it is
stronger and needs no DAQiri number at all: on a correctly configured fabric, gRPC-Direct RDMA runs
at 98.0 percent of line rate.

With the gates passed, the transport was built in stages. First a minimal path with no gRPC, no
protobuf and no shared memory: the PXI writes over RoCE into a `cudaHostAlloc` pool on the Spark and
cuFFT transforms those bytes in place. 1,800 messages across nine sizes plus a 30,000-message soak,
every one spectrally verified, zero completion errors.

**The control ran first, and that is what makes the green runs mean anything.** A deliberately
broken version launches the transform *before* observing the arrival completion, while the write is
still in flight. It failed 59 of 60 times, and the failures reported a 400 kHz tone against an
expected 10 kHz, which is the poison pattern painted into each slot beforehand. So the checker says
*why* it failed, not merely that something is wrong. Two design choices make it capable of failing
at all: the payload tone is a function of the sequence number, so reading the previous message's
leftover bytes fails rather than passing, and each slot is poisoned before every message, so absent
data fails as loudly as stale data. One row of that table is a warning rather than a footnote. At
16 KB, one message in twenty verified clean *with the ordering deliberately broken*, because a small
write can land inside the launch window. The sensitivity of the race test is itself size-dependent,
and a single-message version at a small payload would have reported all-clear on a program with the
race fully present.

That work was then carried into gRPC-Direct proper, using easyrdma's external-buffer interface so
the library writes into a pool we allocate rather than one it allocates. That arm is called `extbuf`
throughout, and it is the deliverable: DAQiri's architecture, reached through the gRPC API.

## 7. Widening the window, and what it showed

Up to this point every latency number in the project started its clock **after** the data had
landed. That was deliberate and it was labelled, because the question had been where the GPU's time
goes. It was never revisited when the question changed to why DAQiri is faster, and by then the
reported window was a small slice of the pipeline it was being read as. None of those numbers
bounded the pipeline.

Measuring the whole path across two machines has an obstacle: the PXI's realtime clock is **23.13
seconds ahead** of the Spark's and neither machine runs a time synchronisation daemon, so
differencing wall clocks between them is worthless. The instrument built instead is a round trip on
a single clock. The sender timestamps before it posts, the receiver transforms and immediately
replies with a 16-byte acknowledgement, the sender timestamps the reply. A calibration arm runs the
same round trip with the transform disabled at 64 points and is subtracted pairwise per repetition,
which removes the request-and-return path itself. Post-to-FFT-complete at 4 MiB came out at about
**1364 us unloaded**, three of three positive. Two caveats travel with it: waiting for the
acknowledgement serialises the sender, so this is the cost of one message with nothing else in
flight rather than the cost per message under load, and one repetition's calibration was an outlier
at 109 us against 23 and 27.

The wider window immediately found something the narrow one could not see, and it was ours. The
sender had been observed blocking about 2205 us per buffer against a 685 us wire time, read for
weeks as a fabric or queue-depth problem. It was neither. Turning off the receiver's per-message
spectral verification moved throughput by **3.18x**, three of three with no overlap. The receiver is
a single thread; the peak search costs about 2400 us of it per message at 4 MiB, and the next
receive call cannot happen until that returns, so the arrival interval is just the consumer's loop
time.

The mechanism first given for this was wrong, and testing it is what produced the real one. The
first explanation was that the check held the received slot between the transform and the re-queue,
starving the sender of credit. That was testable: the check reads the transform's *output* in device
memory and never touches the received slot, so it was moved below the re-queue. The hold time fell
by a factor of 1600, from 2488 us to 1.5 us, and **the throughput did not move at all**. If the
credit window had been the mechanism, the fix would have been free. It is not: verifying every
message at 4 MiB is unaffordable on one thread at any position in the loop, and needs sampling or a
second thread. The same fact explains why a queue-depth sweep across 2, 4, 8 and 16 slots came out
perfectly flat. Buffering absorbs bursts, and this producer is not bursty, it is continuous and
faster than the consumer.

The remaining shortfall turned out to be the benchmark measuring itself. With verification off the
pipeline still sat at about 85 percent of line rate, and the sender was spending 468 us building
each frame plus 335 us inside the send call, which is 803 us of single-threaded memcpy against an
800 us arrival interval. There was no time left for anything else to be the bottleneck. Building the
frames once at startup and writing only a 16-byte header per message dropped the frame build to
0.16 us, and the pipeline moved to **5796 to 5803 MiB/s, 97.3 percent of the 5960 MiB/s payload
ceiling**, with an arrival interval of 663 to 686 us against a 685 us wire time. The send call
rising from 336 to 688 us says the same thing from the other side: with the frame build gone, the
sender waits exactly one wire time and nothing else. The "85 percent of link" figure was the harness
timing its own memcpy, and the faster arm is the *more faithful* one, not a shortcut, because a real
digitizer DMAs into the buffer it hands to the transport and never makes that copy.

**One measurement discipline came out of this and then had to be applied backwards through the
whole document.** The sustained rate had been computed as one over the median inter-arrival gap.
That is only a rate when the arrival cadence is unimodal. On this receive path, when the consumer
stalls, everything that arrived during the stall is reaped back to back and timestamped about 26 us
apart, which at 1 MiB implies 6.5 times the link speed. The cadence is bimodal, the median lands on
the boundary between the two clusters, and the derived figure is fiction. Recomputing every rate as
bytes divided by an elapsed span withdrew a "97.6 percent of wire" claim at 256 KB (honestly 54 to
86 percent, and unstable) and a 1 MiB figure that had been 2.2x too high. The 4 MiB claim survived
and is better supported than before, because at that size mean and median gap agree to 1 percent:
the transfer is long enough that the consumer cannot reap a burst. The rule that came out of it is
that below 4 MiB on this receive path, no median-derived rate is trustworthy.

## 8. Where it ended

One structural fact shapes the final comparison. DAQiri cannot run cross-machine here, because it
links the CUDA runtime and the PXI controller has no GPU, no NVIDIA driver and no CUDA. Its memory
region kind is `host_pinned`, which is `cudaHostAlloc`, so it would fail at the first allocation
even with a runtime installed. **DAQiri requires a CUDA-capable host on both ends.** That is a
property of the product, not of this harness, and it is why every DAQiri number in the project is
Spark-to-Spark loopback.

Rather than compare loopback against wire, both arms were put on the same footing: the gRPC-Direct
RDMA receiver was run in loopback on the Spark too, over the same local RoCE device, matching
DAQiri's topology exactly. Then all four arms were run inside one rotation of one script, in one
thermal window, at one message rate, three repetitions, 1000 measured messages after 500 warmup.

| payload | base | opt | daq | extbuf |
|---|---|---|---|---|
| 16 KB | 15.74 | 11.38 | **9.46** | 10.74 |
| 256 KB | 26.45 | 22.94 | **18.22** | 20.82 |
| 1 MiB | 46.75 | 33.71 | **25.07** | 30.43 |
| 4 MiB | 129.75 | 71.50 | **68.98** | 94.14 |

**DAQiri is faster at every size.** An earlier version of this table had shown a crossover, with
gRPC-Direct ahead at the two small sizes, and that crossover was not real. The two arms in it had
come from two different scripts, one sending back to back and the other with a 400 microsecond
send pace hardcoded. A pacing sweep showed that gRPC-Direct's transform *triples* between 100 and
400 us of pacing while DAQiri's does not move at all, so 400 sat inside one arm's degradation
region and outside the other's. Once both arms were sent at the same rate, both small-size rows
changed sign. The GPU clock was between 2405 and 2548 MHz in every one of those cells, so this is
not thermal, and varying the warmup from 50 to 20,000 messages moved it by under 2 us, so it is not
a cold start. **The mechanism is unexplained and is a live open question.**

The remaining gap at 4 MiB decomposes cleanly, and the decomposition is where the honest ending
lives. Inside that same rotation the cuFFT times were: `base` 47.78 us reading from device memory,
`daq` 64.13 and `opt` 64.99 reading in place from pinned host memory, and `extbuf` 78.40 also from
pinned host.

The fact that `opt` and `daq` land within 0.9 us of each other is what makes the ladder credible.
Those are two entirely different transports on the same class of memory, and they agree. Against
them, `base` transforms 16 us faster, and the reason is that `base` has the alignment optimization
*disabled*, so it copies the payload into device memory first and then transforms device-resident
data. **That 16 us is the priced cost of zero-copy at 4 MiB.** Reading in place from host memory is
slower for the transform than reading from device memory, and the pipeline pays it knowingly,
because the alternative is a copy that costs 77 us. It is a deliberate trade, and it is now
measured rather than assumed.

That accounts for most of the remainder. What is left is `extbuf` sitting 14.27 us above the rung
`daq` and `opt` share, and that number is **open**. It has been bounded rather than explained. Both
named candidates were tested and eliminated: the CUDA stream mode was identical in both arms, and
the slot geometry costs nothing, with a probe that reproduces the receiver's pool exactly showing
that padding the slot stride to a 2 MB boundary costs 0.16 to 0.35 us and moving the payload off
its 256-byte offset onto a page boundary gains 0.26 us. Because that probe reproduces the pool
exactly and still lands on the correct rung, the 14 us is **not in the memory layout**. It is
somewhere in the live pipeline: transforming while the network card writes other slots, or how the
receive thread and the completion gate interleave. Narrower than it was, still unexplained, and
nothing in any current claim depends on it.

So the ending, stated plainly. A real root cause was found and fixed, worth **1.80x** at 4 MB. The
transport itself runs at **98.0 percent of line rate**, and the full pipeline sustains **97.3
percent of the payload ceiling at 4 MiB and only at 4 MiB**: below that size the cadence goes
bimodal, the honest span-derived rate falls to 54 to 86 percent at 256 KB, and the claim does not
travel. Measured fairly, in one window at one message rate, **DAQiri is still faster at every
size**. At the largest payload most of the difference is the deliberate and now-priced cost of
zero-copy, and the last 14 us has been bounded out of the memory layout without being explained.

> [Source notes on this section, in descending order of how much they matter.
>
> **The largest tension between the documents.** The `cudaHostRegister` penalty of section 5
> predicts that `opt`, which transforms iceoryx2 shared memory registered after the fact and does
> have a CPU producer writing every buffer, should be 11 to 15 us slower at 4 MB than `daq`, which
> uses driver-allocated memory. In the corrected table they agree to 0.86 us. An earlier sweep did
> find `opt` slower on the transform in 18 of 18 cells, but that sweep is now attributed to the
> pacing difference. No source document reconciles these. Either the penalty does not survive inside
> the real pipeline, or the pacing correction absorbed it. Worth asking about; I would not assert
> either way.
>
> **Spread.** At 4 MiB the three `extbuf` repetitions were 99.12, 94.14 and 77.55 us, so the
> +25.17 us end-to-end delta is a median over a 21.5 us spread. The transform delta is much tighter,
> 18.40, 14.27 and 14.21 us across the same repetitions, which is why the 14 us figure is quoted
> with more confidence than the 25 us one. Separately, the 16 KB DAQiri cell rests on a single
> repetition, the other two having tripped the clock gate; their raw values agree with the kept one,
> so the row is not in doubt, but it is one sample.
>
> **A stale sentence.** `handoff.md` section 7i says the gRPC and DAQiri paths transform device
> memory after a host-to-device copy, while section 7n's ladder has `opt` and `daq` transforming
> pinned host memory in place. The script settles it: `daq` runs with `--zero-copy` and `opt`
> without `--no-zc-align`, so both transform in place, and only `base` copies. The copy `base` makes
> is device-to-device, not host-to-device.
>
> **A missing comparison.** No full-pipeline, producer-to-spectrum number exists for DAQiri. The
> 1364 us figure is gRPC-Direct only, unloaded, cross-machine. There is currently no full-pipeline
> head-to-head, and the table above is post-arrival processing latency only.]

## 9. Methodology

These are the rules the project settled on, stated as practice. They apply to any benchmark on
hardware whose GPU clocks cannot be locked, which is most shared or unprivileged hardware. Each one
exists because breaking it produced a wrong number at least once.

**Interleave the arms, and rotate their order.** Interleaving removes thermal drift between arms;
the same 4 MB transform has been seen at 45.6 and at 63.2 us minutes apart. Rotating removes
position, which with a fixed order is a hidden variable perfectly correlated with arm identity.

**Report the residual alongside end-to-end.** When the clock sags, end-to-end and transform time
sag together and their difference holds still, so the residual is the quantity that survives drift.

**Three repetitions minimum, then a paired sign test.** A 2.91 us gap from one interleaved run
became a headline and did not replicate. When magnitudes are noisy but ordering is stable, the
count of paired wins is the defensible statistic.

**Include a control that cannot move.** The MTU fix made 4 MB 4.9 percent faster, indistinguishable
from drift on its own; the 2-byte control that could not be affected did not move, which is what
made the effect attributable.

**Match the harness to the producer you are claiming about.** A read-only ladder inverted the
memory conclusion, and a CPU-writing ladder mispredicted a DMA-fed receiver. Time the producer's
write and the transform in one window, because a change that slows one and speeds the other looks
like a pure win when only half is timed.

**Verify that the correctness test can fail.** Run the deliberately broken version first and
confirm it fails for the stated reason, because a check that always passes is indistinguishable
from a check that sees nothing.

**Test the negative case in the same program.** Showing the network card rejects device memory cost
fifteen lines and upgraded a design preference into a hardware constraint.

**A name is not evidence.** An arm labelled as a huge-page test held zero huge pages, because
`madvise` returning success means only that the kernel accepted a hint.

**Timing an asynchronous call times the enqueue.** Compare wall time against GPU event time to find
work billed to the wrong stage; that comparison is what found the 77 us copy.

**A median is not a rate.** One over a median inter-arrival is meaningful only when the cadence is
unimodal. Derive rates from bytes over an elapsed span and quote mean against median if they
differ.

**Stamp every row with the clock and the build.** Peak SM frequency and git SHA per row, with
under-clocked rows marked rather than silently dropped, so an excluded row can still be inspected.

**Withhold a number you cannot support rather than caveating it.** A number that is not printed
cannot be lifted out of a log four weeks later, which is how one contaminated figure survived a
month.

## 10. What a follow-on would do

**Explain the pacing cliff.** gRPC-Direct's transform triples between 100 and 400 us of send
pacing while DAQiri's is flat. Clock and warmup are both eliminated. This is the highest-value open
item because it is currently an uncontrolled variable in every comparison, and until it is
understood, any table taken at an unprofiled pace is partly a report about the pace.

**Close the 14 us.** Both memory-layout candidates are eliminated and the isolated probe reproduces
the receiver's pool without reproducing the cost, so the next place to look is the live pipeline:
whether concurrent DMA into other slots while the transform reads costs anything, and whether the
receive thread and the CUDA completion gate interleave differently in the two arms.

**Build the DAQiri full-pipeline number.** Estimated at 1 to 1.5 days: split the DAQiri benchmark
into client and server roles, which is about half a day since the workers are already separate
functions and the API takes `is_server` as a parameter, then add the round-trip echo instrument and
a calibration arm. It will be Spark-to-Spark and must be labelled as such, but it would give the
project its first producer-to-spectrum comparison rather than a post-arrival one.

**Make per-message verification affordable.** At 4 MiB the spectral check costs 2400 us of the
single receive thread, so throughput and correctness are currently separate runs. Sampling, or
moving the check to a second thread, would let one run answer both questions.

**Re-derive the two unverifiable rates.** The 1.78 GB/s standard-gRPC baseline and the 23.59 GB/s
shared-memory throughput figure have no recorded construction and no surviving per-message data.
They are still quoted in project material. They should be re-run with the current harness, which
emits a span-derived rate, or dropped.
