# HANDOFF: gRPC-Direct latency optimization (CURRENT, 2026-08-21)

> Paste this into a new chat to continue. It is self-contained: everything a fresh session
> needs about the goal, the system, what has been measured, and what to do next.
> The previous RoCE-era handoff is preserved at `handoff_roce_2026-08-06.md`.

---

## 0. One-line status

gRPC-Direct was 1.76x slower than DAQiri at 4 MB. We found the cause (an incorrect alignment
assumption forcing an unnecessary GPU copy on 100% of messages), fixed it, and closed most of
the gap. A dedicated CUDA stream took a little more. **At 4 MB the gap is now 8.10 us, about
13%.** Roughly 80% of what remains is inside cuFFT rather than in transport.

**The transform finding has been narrowed, and the headline it used to carry is withdrawn.**
This document previously opened by saying we knew why the transform was slower and that owning
the buffer allocation was worth about 15 us at 4 MB. That is no longer a claim this project
makes. Read section 7g before quoting anything from 7c or 7e.

What 7c measured is real and repeats: with a CPU producer writing every buffer, driver-allocated
pinned memory transforms about 7 to 11 us faster at 4 MB than memory we allocate and hand to
`cudaHostRegister`, and the producer's write is about 2x faster too. Five of five reps, and
7e shows no flag on either side closes it.

What was wrong is the scope. **Remove the CPU write and the sign inverts**: registered memory
becomes 11.25 us faster, also 5 of 5. So the penalty is not a property of the memory. It is a
property of the interaction between the producer's stores and the transform's reads, and
`cudaHostRegister` changes that interaction. 7c hinted at this and did not follow it: registration
has no business changing CPU store speed, and it doubles it, which means it is changing the
page's cacheability.

The consequence is that the figure applies to the shmem path, where a CPU producer really does
write every buffer, and **does not transfer to an RDMA receiver, where a NIC writes the buffer
and the CPU never touches it.** That was checked directly: a four-arm 4 MB cell in the real
receiver put our own `cudaHostAlloc` pool against driver-allocated buffers and found them
indistinguishable, 0.5 us with the sign changing between reps. Sections 7g and 7h.

**So the RDMA transport's original justification is withdrawn.** It was started because owning
the receive allocation was worth 10.94 us. It is not, on that path. The reasons to keep it are
the ones that never depended on 7c: no per-buffer registration, no unregister on teardown, a
fixed slot pool, and a release-before-completion gate we control. Those are correctness and
steady-state arguments and should not be written as a microsecond argument.

**Current work: give gRPC-Direct DAQiri's actual transport.** A RoCE RDMA write from the PXI
landing directly in a `cudaHostAlloc`'d receive buffer that cuFFT reads in place. All four
pre-flight gates passed on 2026-08-19; section 7d has the results and the reproduction steps.
**Phase 2 is built and passing:** 31,800 messages from the PXI across payloads from 16 KB to
4 MB, every one spectrally verified, zero completion errors, and nothing allocated or registered
after startup. The deliberately-broken-ordering control fails as it must, so the checker is
known to be sensitive to the race rather than merely green. Section 7f.

**Phase 3 is under way and the scoping changed its shape twice.** The Rust library already
implements the RDMA transport over easyrdma; the "not yet implemented, returns NULL" comment is
stale. But it lets easyrdma allocate the landing buffer, which is the arrangement Phase 1
measured and Phase 2 exists to escape. `easyrdma_ConfigureExternalBuffer` is the seam, and the
audit below confirms it is called nowhere, so it must be bound rather than switched on. Full
breakdown, including the three buffer-ownership questions, in `rdma_transport_plan.md` §6.

**Gate 5 passed on 2026-08-20 and the premise of Phase 3 holds.**
`easyrdma_ConfigureExternalBuffer` accepts a 64 MiB `cudaHostAlloc` pool, the payload lands at
the offset we choose, the rest of the pool is untouched, and a GPU kernel reads the received
bytes in place. The negative control with stock `ConfigureBuffers` lands outside the pool while
still transferring, so it is a live control. 17 checks, 0 failures, 3 reps at different sizes
including an unaligned offset. `scripts/gate5_extbuf.cu`, output in `data/gate5_extbuf.txt`.

The gate corrected three things the plan had wrong, all in `rdma_transport_plan.md` §6.4.
External buffers complete **by callback only** (`AcquireReceivedRegion` throws
`InvalidOperation`), there is **no release call** (the slot returns to idle on completion, so
re-queueing is the only re-arm), and teardown needs
`easyrdma_CloseFlags_DeferWhileUserBuffersOutstanding` or the heap corrupts. It also confirmed,
as predicted from source, that **RX polling and external buffers are mutually exclusive**
(-734026). That is a Phase 4 confound: the `rdma` arm cannot poll and `rdma-stock` can, so an
`rdma-stock-nopoll` arm is needed to isolate allocation ownership from wakeup mechanism.

**The fork is now a branch, and the divergence is larger than the first two audits found.**
`daqiri-extbuf` is published at `https://github.com/dvthomas01/grpc-direct`, forked from
`ni/grpc-direct` at `2d404a5`. `ni/grpc-direct` itself is private and read-only to us: a
dry-run push returns 403, so upstreaming needs either write access or a pull request from the
fork. The branch sits off upstream `2d404a5` and the measured state is commit
`5dfeaa5`: fifteen files, +1508/-39. Read `git diff 2d404a5 daqiri-extbuf` rather than any of
the hash comparisons. Beyond the two files already reported (`cpp/client_interceptor.cc` and
`plugin/cmd/protoc-gen-grpc-direct/gen_cpp.go`) it also carries a `python/` package restructure
and two `examples/` additions. Neither is on the benchmark path: `examples/` is not built by our
CMake and `python/` is not linked. They were missed because the earlier comparison that produced
"144 files identical" was **Spark against PXI**, and both boxes already had them, so they hashed
equal. The comparison that produced "125 of 127 identical" was **PXI against upstream**, and the
PXI is not the machine the gRPC numbers came from. `LONGTERM_CONTEXT.md` now tabulates all three
pairings before describing any of them.

That PXI audit still stands on its own terms: no `.git`, four `lib.rs.bak` files, provenance by
hashing against a fresh clone of `ni/grpc-direct`, `src/lib.rs` +529/-31 in five coherent
changes, `.bak` files monotone with nothing reverted. Two carry-forwards: upstream has a real bug where
`PROPERTY_USE_RX_POLLING` is set after `ConfigureBuffers` and therefore silently does nothing,
so an `rdma-stock` arm must be built from the fork with our changes off rather than from
upstream; and the fork's re-accept loop turns a peer disconnect into an indefinite stall instead
of an error. See `rdma_transport_plan.md` §6.5. If you re-run the comparison, clone with
`core.autocrlf=false` or it will report 123 of 127 files changed and mean nothing by it.

**Both machines are up as of 2026-08-20.** The Spark was off the network for part of the day and
returned at the same address after a power cycle. Two things that outage taught, both durable:
`ip neigh` must be flushed before it is believed, because the first check reported the Spark
alive with its correct MAC from a stale cache entry; and the PXI's RoCE address dies on a **Spark
power cycle**, not only on a PXI reboot. The PXI had 13 days of uptime and had still reverted to
a `169.254/16` link-local address, because the carrier flapped. Recovery is
`scripts/roce_restore_pxi.sh` as root on the PXI. The GID index moves with the address, so read
it rather than quoting one from memory. **Fixed 2026-08-20:** both RDMA endpoints now default to
`gid_index = -1` and call `rdma::find_roce_v2_ipv4_gid()`, which selects by peer address.
Verified end to end with no `--gid` on either side. See `LONGTERM_CONTEXT.md` for the measured
GID tables and the two ways a naive search gets this wrong.

**Every gRPC number in this repo was produced against a modified `grpc-direct`, and the
modification is inert for our workload.** The Spark's working tree carries an uncommitted
+16/-5 edit to `cpp/client_interceptor.cc`, and that file is on our path beyond any doubt:
`CMakeLists.txt:299-301` compiles it into `grpc_direct_cpp`, `cpp/client_interceptor.cc:389`
defines `DirectTransportInterceptorFactory::CreateClientInterceptor`, and
`grpc_direct/bench_grpc_client.cc:114` constructs that exact factory and hands it to
`CreateCustomChannelWithInterceptors` at line 118. So the answer to "is it linked" is yes.
The answer to "does it change our numbers" is no, and the reason is specific rather than
reassuring. Our RPC is **client-streaming**, not unary: `pipeline_fft.proto:14` declares
`rpc StreamBuffers(stream BufferRequest) returns (PipelineSummary)`. The edit's one behavioural
branch is guarded at `client_interceptor.cc:267-268` by
`callType == ClientRpcInfo::Type::SERVER_STREAMING`, which we are not. The three unguarded
additions all key off `serverStreamEnded_`, which is only ever set at lines 300 and 327, both
of which require `responseSize == 0`. That cannot happen for us: `PipelineSummary` carries
fourteen non-default numeric fields, and `data/headline_runs.csv` shows a non-zero `fft_p50` in
every row. `fft_p50` is measured on the server with CUDA events and reaches the client only
inside that response, so a populated column is proof the response was received and parsed and
that `FailHijackedRecvMessage()` never fired. Our send path (lines 238-249, the
`CLIENT_STREAMING` branch) is untouched by the diff. The remaining hunk is a whitespace mangle
at line 200 with identical semantics.

**If you read only one more thing, read section 1.** Five of this project's headline numbers
turned out to be measurement artifacts or overreaches rather than results, and all five were
caught late. Sections 5, 7c and 7g contain the retractions. **7g retracts part of 7c**, so read
them as a pair or not at all. **7i is the sixth**, and it is the largest: the sender's 2205 us
stall was the receiver's own spectral check holding the slot, and removing it is worth 3.18x.

**The pipeline now has a transport number, and it did not before (7i).** Every latency figure
in this document above section 7i starts its clock after the data has landed. That was
deliberate and labelled, but it means none of them bounded the pipeline. Post-to-FFT-complete
from the PXI at 4 MiB is about **1364 us unloaded**, measured by round-trip echo on the sender's
single clock because the two boxes' realtime clocks differ by 23.13 seconds and neither runs
NTP. Sustained, with the receiver's verification moved out of the credit window, the path runs
at **4983 MiB/s, 85 percent of line rate**, up from 27 percent. Slot depth is closed negative.
What limits it now is the sender's own CPU doing two 4 MiB host memcpys per message.

### Where to look for what

| Section | Contents |
|---|---|
| 1 | How to measure on this box. Read before running anything. |
| 5 | Current scoreboard and the retracted 2.91 us gap |
| 7 | Why we do not own the payload allocation |
| 7b | The three device-landing routes, costed. **Its ranking is retired by 7d.** |
| 7c | `cudaHostAlloc` versus `cudaHostRegister`. **Scope narrowed by 7g. Do not quote alone.** |
| 7d | The RoCE-into-`cudaHostAlloc` design, the four gates, and the machine state that dies on reboot |
| 7g | What the 10.94 us actually belongs to, and why it does not transfer to RDMA |
| 7h | The 4 MB Phase 4 cell: the two provenances measured in the real receiver. **Its throughput and blocked-send figures are contaminated; see 7i.** |
| 7i | The transport number, the 3.18x from moving verification out of the credit window, slot depth closed negative, and the sender's CPU as the new bound |

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
4. **Rotate the arms, do not merely interleave them.** Interleaving removes drift between arms,
   but with a fixed order the arm listed first always runs in the same slot, so position becomes
   a hidden variable perfectly correlated with arm identity. The signature is a first-listed arm
   winning every single cell. Rotate the starting arm: `arms[(it + k) % arms.size()]`. Doing this
   to the memory ladder did not erase its effect, it grew it from 7.17 to 10.94 us at 4 MB, but
   you cannot know which until you check.
5. **Dirty the buffer the way the real producer dirties it.** A ladder that only reads the
   buffer understates host memory badly enough to invert the conclusion, and so does a ladder
   that CPU-writes a buffer the real system fills by DMA. Both of those happened here, in that
   order. The rule is not "always write", it is **match the harness to the producer you are
   claiming about**, and say in the write-up which producer that was. **Time the producer write
   and the transform together**, because a change that slows the write and speeds the transform
   looks like a pure win when only half the window is timed.
6. **Include a control that should not move.** When the RoCE MTU was raised, 4 MB got 4.9%
   faster, which alone is indistinguishable from drift. A 2-byte message measured in the same
   pair of runs cannot be affected by MTU, and it did not move. That is what turns the 4 MB
   number into a measurement. A control that stays still is cheaper than a repeat run and proves
   more. Related: **baseline, change, remeasure**, even when the change is obviously correct,
   because otherwise you get one number with nothing to attribute it to.

**Five burns, so you can recognise the shape of them.**

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
- *One rep is not a measurement.* That 2.9 us gap then became the headline. It came from a
  single interleaved run and did not replicate; two reps put it at 8.10 us. Interleaving removes
  bias between arms but tells you nothing about how much a number moves between runs.
- *A read-only benchmark answering a question about writes.* The rebuilt memory ladder was
  interleaved, repeated and sign-tested, and it declared memory kind dead. It never wrote to the
  buffer. Adding the CPU write that every real pipeline performs separated the arms by 10.94 us
  of transform time at a 4 MB payload, p = 6.1e-05, and produced the mechanism the whole project
  had been looking for. The read-only caveat had been written down at the time and not acted on.
  **Amended 2026-08-21, and this is the more interesting half.** The read-only ladder was not
  wrong and should not have been filed here as a burn. It was answering a different question
  correctly, and the question it answers is the one the RDMA receiver actually asks, because a
  NIC writes that buffer and the CPU never does. Both measurements were right about their own
  configuration. The mistake was carrying one of them into a configuration it had not measured,
  which is a harder mistake to see than a bad measurement and cost considerably more. See 7g.
- *A result that travelled further than the configuration that produced it.* 7c was measured
  with a CPU producer dirtying every buffer, then quoted as a fact about buffer provenance in
  general and used to justify building a transport. Removing the CPU write inverts the sign.
  **Before a number leaves the harness that produced it, write down what the harness did that
  the target system does not do.** In this case: a CPU store per buffer, one buffer reused for
  thousands of iterations, and no DMA anywhere.

**A name is not evidence.** An arm labelled as a huge-page test had been reported as one on the
strength of `madvise(MADV_HUGEPAGE)` returning 0. That return value means the kernel accepted a
hint. `/proc/self/smaps` showed the arm held zero huge pages, so its null result said nothing at
all about page size. Verify the mechanism you claim to be testing, from the system's own
accounting, not from the API's return code.

**Test the negative case in the same program.** Gate 4 proved the NIC accepts CUDA-pinned host
memory. Fifteen extra lines attempting the identical registration on device memory got a
rejection, which upgraded "we chose host memory" to "host memory is the only option this
hardware offers". The pair is worth far more than the positive alone.

**One more, about sample counts.** Warmup discards the first N *received* messages, not the
first N sequence numbers. An early loss burst therefore shifts the measurement window forward
instead of punching holes in it. Check sequence *contiguity*, not row count, before you
conclude anything about drops. `scripts/check_drop_bias.py` does this.

## 2. What we are trying to do

Make gRPC-Direct's end-to-end latency match or beat DAQiri's RoCE path, while:

- keeping the gRPC API structurally the same (optimize on top of it, do not replace it),
- putting every optimization behind an opt-in mode flag so the baseline stays measurable,
- proving correctness (spectral output) before trusting any speedup.

The cross-machine RoCE work was shelved during the optimization arc and has now been
deliberately restarted. The original reason was that the evidence in 7c pointed at the receive
buffer's allocator, and the only way to own that allocation is to own the transport. **That
reason no longer holds**: 7g shows the 7c penalty needs a CPU producer write, which an RDMA
receiver does not have, and 7h measures the two allocations head to head in the real receiver
and finds no difference.

The work continued anyway, on grounds that stand on their own. Owning the receive path gives a
fixed slot pool with no per-buffer registration, no unregister on teardown, and a
release-before-completion gate we control, and the claim being built is "DAQiri performance
without giving up the gRPC API", which was the original project goal and never depended on 7c.
But the honest position is that a microsecond justification was replaced by a correctness one
part-way through, and anyone reading this should know that rather than infer it. See 7d, 7g,
7h.

## 3. Where the work lives

- **Branch:** `grpc-direct-optimization`, cut from `main` at 57ba6d3. **`main` is untouched.**
- **Commits on the branch**, oldest first:
  - `5eaaf89` instrument the residual + fix the alignment rule (Phase 0, E1, E2)
  - `4de101c` E3/E4 measured and rejected + fix wrong CUDA arch
  - `a35bdb6` handoff docs
  - `3cf63de` seq accounting, dedicated CUDA stream, interleaved measurement
  - `1051444` sweep refuses to run on a stale binary, stamps the build into the CSV
  - `952b68a` `scripts/find_spark.sh`
  - `efe712d` headline sweep, 2 reps interleaved, and the reversal on where the gap lives
  - `50ce845` placement probe: registration granularity is not the mechanism
  - `b8c0b96` i-RDMA feasibility: CPU cannot write device memory, managed memory does not stay
  - `f5e5b79` page size is innocent, `cudaHostRegister` is the mechanism (retracts the null)
  - `c91614c` Gates 1 and 4 pass
  - `c875e0c` Gate 3 passes
  - `0c26669` Phase 0.5: the comparison is post-arrival processing latency, not end-to-end
  - `6070ae1` Phase 1 harness: the allocator-flag arms
  - `dc5eb4a` Phase 1 results, and a two-sided fix to `sign_p` in `scripts/memsrc_table.py`
  - `eb83fe9` Phase 1 evidence log, force-added over the `*.log` ignore
  - `7a952b1` every quotation of the 10.94 \u00b5s figure now carries its payload size
  - `7a49963` Phase 2: bytes cross the cable, land in `cudaHostAlloc` memory, transform correctly
  - `6a8056f` Phase 3 step 5 runs: the external-buffer path works end to end
  - `1910b36` Phase 4 harness: clock gate and warmup, plus the stock RDMA arm
  - `5d5921c` plan: lock the Phase 4 scope and record what the stock arm cost
  - `b498987` Phase 4: the 4 MB cell, and the 7c penalty does not reproduce
  - `14778ab` memsrc 2x2: the 10.94 us belongs to the CPU write, not to the memory
- `origin/grpc-direct-optimization` is at `14778ab`, the same as local, so the branch is
  **pushed and clean**. Ask before pushing. Git identity: Dami Thomas, damithomas03@gmail.com.
  Remote `https://github.com/dvthomas01/DAQIRI_v_GRPC.git`.
- **Note:** `PROGRESS.md`, `SHORTTERM_CONTEXT.md` and `LONGTERM_CONTEXT.md` **are committed as
  of 2026-08-20**. They used to be gitignored while this file and two others pointed readers at
  them, so they were cited as authoritative and were unreadable by anyone else. `RESULTS.md`,
  `M9_REPORT.md` and `ARCHITECTURE.md` are still local-only, and `PROGRESS.md` flags the one
  link that therefore will not resolve.
- **Also note:** the previous RoCE session left a lot of uncommitted work in the working tree
  (RoCE pipeline sources, `data/*.csv`, `presentation/`, many `scripts/probe_*.sh`). It is
  untracked and shared across both branches. It was deliberately left alone. Do not commit it
  to the optimization branch. **Always `git add` explicit paths, never `git add -A`.**

### Probes and evidence added during the current arc

| File | What it is |
|---|---|
| `fft/bench_fft_memsrc.cc` | The placement ladder. Same cuFFT plan over each memory kind, no gRPC, no network. `--sizes` is in **samples**, not KB. |
| `scripts/memsrc_table.py` | Parses its CSV, prints write / transform / total tables plus paired sign tests |
| `scripts/gate1_caps.cu` | GPU capability probe (Gate 1) |
| `scripts/gate4_regmr.cu` | `ibv_reg_mr` over a `cudaHostAlloc` buffer, with the device-memory control (Gate 4) |
| `rdma/rdma_fft_server.cu` | Phase 2 receiver. Spark side: the pool, the ordering rule, the hot-path assertions, and `--break-ordering`. Build target `rdma_fft_server`. |
| `rdma/rdma_fft_client.cc` | Phase 2 sender. Builds on the PXI with `g++ ... -libverbs`, no CUDA. |
| `rdma/rdma_contract.h` | The sequence-number-to-tone mapping both sides must agree on. One definition on purpose. |
| `data/p2_break.log`, `data/p2_correct.log`, `data/p2_soak.log` | Phase 2 raw output, including the run that is supposed to fail |
| `rdma_transport_plan.md` §6 | Phase 3 scoping: what the fork looks like, where the easyrdma seam is, the three ownership questions |
| `scripts/phase3_scope_probe.sh` | Re-runs that scoping read against the PXI. §6 cites `src/lib.rs` line numbers; this is how to check them |
| `scripts/find_spark_arp.sh` | Settles whether the Spark is off the network or just at a new address. Flushes ARP first, which matters |
| `scripts/roce_poststate.sh` | Read-only RoCE state check for either machine: address, MTU, port state, `active_mtu`, GID indices |
| `scripts/roce_restore_pxi.sh` | Root on the PXI. Re-adds `192.168.20.2/24` and mtu 9000, then re-reads the GID indices. Run after every Spark power cycle |
| `scripts/diff_grpc_direct_upstream.ps1` | Hashes the PXI's `grpc-direct` against an upstream clone. Clone with `core.autocrlf=false` or it reports nonsense |
| `scripts/audit_libr_baks.sh` | Answers what the four `lib.rs.bak` snapshots contain that the current `lib.rs` does not. Answer: nothing |
| `scripts/gate5_extbuf.cu` | Gate 5. Does easyrdma land RDMA writes in a `cudaHostAlloc` pool we own? Yes. Self-contained, runs on the Spark alone over RoCE loopback |
| `scripts/run_gate5.sh`, `scripts/gate5_reps.sh` | Build-and-run for Gate 5, and the three-rep sweep across sizes and offsets |
| `scripts/probe_easyrdma_userbuf*.sh` | Read-only reads of the easyrdma source that established the external-buffer protocol. `userbuf3` is the one that found the callback-only completion |
| `data/pagesize_rot.csv` | The rotated-order run behind the 10.94 us at 4 MB result. **Read with 7g: that figure needs a CPU producer write and does not transfer to the RDMA path** |
| `data/memsrc_2x2_1048576.csv`, `data/memsrc_2x2_nowrite_1048576.csv` | 7g. The same four arms with and without the producer's CPU write. The sign inverts between the two files |
| `data/phase4_cell_1048576.csv` | 7h. The 4 MB Phase 4 cell, three arms x five reps, with `sm_mhz` and the git SHA on every row |
| `data/gate1_caps.txt`, `data/gate3_fabric.txt`, `data/gate4_regmr.txt` | Raw gate output |
| `data/gate5_extbuf.txt`, `data/gate5_reps.txt` | Gate 5 output and the three reps |

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

**What these numbers measure, corrected 2026-08-19.** This is **post-arrival processing
latency**, not end-to-end networked latency. Every arm's clock starts after the buffer has
landed and stops after the FFT: DAQiri takes `t_rx` once the RECEIVE completion is
dequeued and documents the column as "received-buffer-in-hand -> post-FFT (RX-side wall
clock)", and the gRPC server takes `t_recv` on handler entry. Time in flight is outside
the window for both.

**The DAQiri arm is a single-process, single-device RC loopback**, not a networked run.
`bench_daqiri_roce_pipeline.cc` hardcodes `SERVER_ADDR` and `CLIENT_ADDR` both to
`192.168.20.1`, the Spark's own RoCE IP, so TX and RX are two threads in one process on
one NIC and the PXI is not involved. Two independent checks confirm it: at 50 Gb/s the
wire time alone for 4 MB is 671 us against a reported 62.31, and Gate 3 measured a real
PXI-to-Spark 4 MB write at 694.76 us. From 256 KB upward the reported e2e is below the
theoretical wire time, which is only possible if no wire was crossed.

None of the numbers change. The gap is real and the arms are comparable to each other,
because both producers are local and both windows are identical. Only the label was
wrong. Quote it as post-arrival processing latency and name the DAQiri arm as loopback.
See `rdma_transport_plan.md` section 3.

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
| `--zc-bigreg` | **E4:** register whole 64 KB GPU pages like DAQiri | rejected: 77.5 vs 76.4, no effect; re-tested under write-then-transform discipline in 7e, null again |

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

## 7c. RETRACTION: memory kind is not dead, and we found a mechanism (2026-08-19, SCOPE NARROWED BY 7g)

> **SCOPE NARROWED BY 7g, 2026-08-21. Do not quote this section on its own.** Everything
> measured here repeats. What is wrong is the last two words of the heading and the section
> that follows the result table. The effect belongs to the CPU producer's write, not to the
> memory, and removing the write inverts its sign. It applies to the shmem path and does not
> transfer to an RDMA receiver. The paragraph below saying this matters more than the RDMA
> route is withdrawn.

Section 7b and the earlier memory-kind ladder both concluded that where the buffer comes from
does not matter. **That conclusion was wrong, and the reason it was wrong is worth more than
the conclusion.** The ladder that produced it never wrote to the buffer before transforming
it. Real pipelines always do. Once a CPU store precedes the transform, the arms separate
immediately and stay separated.

> Amendment: the shmem pipeline always does. The RDMA receiver never does, and that is the
> whole of 7g.

### What backs each mapping (from /proc/self/smaps, 4 MB payload)

The harness now walks its own `smaps` and prints the backing of every arm, because a name is
not evidence:

```
hostalloc  pagesize=4kB rss=6144kB anonhuge=0kB    back=/dev/zero (deleted)              vmflags: rd wr sh mr mw me ms
heapreg    pagesize=4kB rss=4096kB anonhuge=0kB    back=anonymous                        vmflags: rd wr mr mw me ac
shmreg     pagesize=4kB rss=4096kB anonhuge=0kB    back=/dev/shm/fft_memsrc_probe (del)  vmflags: rd wr sh mr mw me ms
hugereg    pagesize=4kB rss=4096kB anonhuge=4096kB back=anonymous                        vmflags: rd wr mr mw me ac hg
```

Two things fall out of this immediately:

1. **`cudaMallocHost` is 4 KB pages too.** It is a `MAP_SHARED` mapping of a deleted
   `/dev/zero`, with vmflags byte-identical to our `/dev/shm` arm. DAQiri's memory and our
   memory are the same class of object to the kernel. The page-size hypothesis is refuted at
   the source: there is no page-size difference to explain anything.
2. **The old huge-page arm never had huge pages.** `madvise(MADV_HUGEPAGE)` returning 0 means
   the kernel accepted a hint, not that it promoted anything. The arm is only a real
   huge-page arm at payloads of 2 MB or more; below that it silently duplicated `heapreg`,
   and it had been reported as "THP" on the strength of the return code alone. The harness now
   prints `WARNING: 'hugereg' got NO huge pages` when `AnonHugePages` is zero.

`MAP_HUGETLB` is unavailable on this box regardless: `HugePages_Total: 0`, and filling the
pool needs root. THP at 2 MB is the only huge-page mechanism reachable as `nitest`.

### The result: page size is innocent, registration is guilty

4 MB payload, 15 reps, 200 iterations, arms rotated so no arm keeps the same slot:

| arm | how it was built | write | transform | total |
|---|---|---|---|---|
| `hostalloc` | `cudaHostAlloc` | **56.75** | **53.22** | **109.83** |
| `heapreg` | `malloc` + `cudaHostRegister` | 118.66 | 63.07 | 181.87 |
| `shmreg` | `/dev/shm` + `cudaHostRegister` | 117.49 | 64.19 | 181.57 |
| `hugereg` | 2 MB THP + `cudaHostRegister` | 114.53 | 66.91 | 181.65 |

Sign tests, paired per rep: `heapreg`, `shmreg` and `hugereg` are each **0/15** faster than
`hostalloc`. `shmreg` slower than `hostalloc` **15/15, p = 6.104e-05**, by 10.94 us of GPU
time at this 4 MB payload. Section 7e later shows this penalty is size-dependent and does not
exist below about 1 MB, so the figure travels with its size or not at all.

Applying the decision rule stated before the run: the huge-page arm was to indict page size if
it matched `hostalloc` and exonerate it if it matched `shmreg`. **It matched `shmreg`**, at
181.65 against 181.57, with `hostalloc` 72 us away. Verified 2 MB pages bought nothing.

The three slow arms have nothing in common except `cudaHostRegister`. They differ in page size
(4 KB vs 2 MB), in sharing (`MAP_PRIVATE` vs `MAP_SHARED`), and in whether they were
pre-faulted. They land within 0.3 us of each other. The one fast arm is the one the driver
allocated. Both paths then go through `cudaHostAllocMapped` / `cudaHostRegisterMapped` and
`cudaHostGetDevicePointer`, so the device pointer is obtained identically and cannot be the
difference.

**Driver-allocated pinned memory beats user-allocated-then-registered memory, on both halves:
about 2x on the CPU write and about 11 us on the GPU transform, both at 4 MB.** That the CPU
write is
affected at all is the strongest clue to the mechanism, since registration has no business
changing CPU store speed unless it also changes the page's cacheability or coherency
attributes. On a C2C-coherent part that is a plausible thing for `cudaHostRegister` to do.

### Why this matters more than the RDMA route

> **WITHDRAWN 2026-08-21.** The argument below is left in place because it is the argument the
> next four weeks of work were built on, and deleting it would hide that. It is wrong in one
> specific way: it assumes the 10.94 us follows the buffer into any transport. It does not.
> It follows the CPU write, and the RDMA receiver has no CPU write. See 7g and 7h.

Our pipeline receives an iceoryx2 buffer from `/dev/shm` and must `cudaHostRegister` it.
DAQiri calls `cudaMallocHost`. So DAQiri sits on the fast side of this effect and we sit on
the slow side, by construction, and **10.94 us at 4 MB is larger than our entire remaining
8.10 us
gap.** This is very likely the mechanism we have been hunting, and unlike Route B it does not
require an RDMA transport that does not exist yet.

It does still run into the section 7 seam, since iceoryx2 owns the allocation. But the ask
changes shape completely: not "move the data to the GPU" but "have the transport hand us
memory the CUDA driver allocated". Confirmed by reading `iceoryx2-bb-posix-0.7.0`:

* `shared_memory.rs:185` allocates with `shm_open`, so segments are always `/dev/shm`.
* `shared_memory.rs:588-597` hardcodes `posix::MAP_SHARED` with no flag hook.
* `MAP_HUGETLB`, `MADV_HUGEPAGE` and `hugetlb` appear **nowhere** in `iceoryx2-0.7.0`,
  `iceoryx2-bb-posix`, `iceoryx2-cal` or `iceoryx2-pal-configuration`. The only hits in the
  tree are unused constants in generated bindings.
* The configurable paths (`ICEORYX2_ROOT_PATH`, `TEMP_DIRECTORY`) are compile-time `const`s,
  not runtime config, and they do not govern the shm segment location anyway.

So there is no config line. Pointing iceoryx2 at hugetlbfs would be a patch to a crates.io
dependency, and page size is innocent so it would buy nothing even if it worked.

### What to test next, in order

1. Whether the penalty is inherent to `cudaHostRegister` or to how we call it. Try
   `cudaHostRegisterDefault` and `cudaHostRegisterPortable` against `cudaHostRegisterMapped`
   on the same `/dev/shm` buffer. Cheap, and it is the difference between "unfixable without
   changing iceoryx2" and "one flag".
2. Whether registering once at startup and never again removes it. The pipeline registers per
   slot. `--zc-bigreg` tested span granularity and was null, but that was before we knew to
   dirty the buffer first, so it deserves a rerun under the write-then-transform discipline.
3. Only then, whether iceoryx2 can be handed a pre-allocated `cudaHostAlloc` region. That is
   the Rust-side change, and it should not be started until 1 and 2 are ruled out.

**Items 1 and 2 are now answered, both negative. See section 7e.** Item 3 is therefore live.

### Method note

The first version of this run had the arms in fixed order, and `hostalloc` was listed first
and won 15/15 against all three others. A first-listed arm winning everything is what an order
effect looks like, so the loop was changed to rotate the starting arm each iteration even
though a comment already claimed it did. The effect survived and grew, from 7.17 us to
10.94 us, both at 4 MB. Interleaving is not the same as rotating, and only the second one
removes position
as a hidden variable.

## 7d. RoCE straight into `cudaHostAlloc` memory: the four pre-flight gates (2026-08-19)

### The design in one paragraph

The PXIe-8881 does an RDMA write over RoCE into a buffer on the Spark. That buffer was
allocated with `cudaHostAlloc` plus `cudaHostAllocMapped` and registered with the NIC via
`ibv_reg_mr`. The Spark polls the completion, then hands cuFFT the device pointer from
`cudaHostGetDevicePointer` and transforms in place. Nothing is copied. The NIC writes once and
the GPU reads what the NIC wrote. It is still zero-copy, it just terminates in host memory
rather than device memory, because on this chip host memory is what the GPU reads from anyway.

This is DAQiri's architecture. DAQiri already does RoCE into `cudaMallocHost` buffers. The
claim is not a faster path, it is "DAQiri performance without giving up the gRPC API", which
was the original project goal. ~~The reason to expect it to work is 7c: `cudaHostAlloc` beats
`cudaHostRegister` by 10.94 us of transform time at a 4 MB payload, which is larger than the
remaining 8.10 us
gap to DAQiri.~~ **Struck 2026-08-21: that reason is withdrawn, see 7g and 7h.** The claim in
the sentence before it is unaffected, since matching DAQiri's architecture was never contingent
on the registration penalty. Today iceoryx2 allocates the buffers with `shm_open` and we
register them after the fact. Owning the allocation is still the point, but for the reasons in
7g's closing list rather than for a microsecond figure.

### Gate results

| Gate | Question | Result |
|---|---|---|
| 1 | Does the GPU permit host pointers for registered memory? | **PASS**, and it also killed the device-memory route |
| 2 | Is RoCE up on both ends with a usable address? | **PASS** |
| 3 | Does RoCE work end to end, and what is the latency floor? | **PASS**, at 98% of line rate |
| 4 | Will `ibv_reg_mr` accept CUDA-pinned memory? | **PASS**, decisively |

All four pass, so the architecture is feasible and the next step is the flag experiment.

Evidence is committed at `data/gate1_caps.txt` and `data/gate4_regmr.txt`; the probes that
produced them are `scripts/gate1_caps.cu` and `scripts/gate4_regmr.cu`.

**Gate 1** returned `CAN_USE_HOST_POINTER_FOR_REGISTERED_MEM = 1`, and the allocation confirmed
it rather than merely asserting it: `cudaHostAlloc` returned `0x32ee00000` and
`cudaHostGetDevicePointer` returned the same address, 2 MB aligned. So
`cudaHostGetDevicePointer` is optional here, not load-bearing.

Gate 1 also settled the route ranking with hardware evidence instead of judgement.
`GPU_DIRECT_RDMA_SUPPORTED = 0` and `DMA_BUF_SUPPORTED = 0`, but
`HOST_ALLOC_DMA_BUF_SUPPORTED = 1`. Third-party DMA into device memory is unsupported on GB10;
third-party DMA into page-locked host memory is supported. Section 7b ranked GPUDirect RDMA
first. That ranking is retired. Landing in host memory is not the second-best option, it is the
only one the hardware offers.

`nvidia-peermem` is present at
`/lib/modules/6.11.0-1016-nvidia/kernel/nvidia-580-open/nvidia-peermem.ko`, version 580.95.05,
but is not loaded, and `modprobe` fails with "Operation not permitted" because `nitest` has no
passwordless sudo. This is moot: peermem exists to expose device memory to the NIC, and device
memory is not on the table.

**Gate 4 is the one that mattered.** `ibv_reg_mr` succeeded on a 4 MB `cudaHostAlloc` buffer,
returning lkey and rkey `0x00182ae7`, with `mr->addr` and `mr->length` matching the CUDA
allocation exactly. A GPU kernel then wrote the region and the CPU read it back coherently, so
the NIC and the GPU address the same bytes rather than two aliases of the same size. The
control in the same program attempted the identical registration on `cudaMalloc`'d device
memory and was rejected with "Bad address". Host landing is therefore a demonstrated constraint
on this hardware, not a design preference, and that sentence is worth more in a pitch than the
positive result on its own.

### Gate 3: the fabric is not the problem

`ib_write_lat` and `ib_write_bw`, PXI as client writing into the Spark as server, which is the
direction the real design uses. Measured twice on purpose: once at the MTU we found, then again
after aligning it, so the MTU effect is attributable instead of being folded into a single
number.

| measurement | MTU 1024 | MTU 4096 | delta |
|---|---|---|---|
| 2 B write, t_typical | 1.81 us | 1.82 us | none, as expected |
| 4 MB write, t_typical | 730.29 us | 694.76 us | **-35.5 us, 4.9% faster** |
| 4 MB write bandwidth | 5518.37 MiB/s | 5843.23 MiB/s | **+324.9 MiB/s, 5.9%** |

The 2-byte row is the control. MTU cannot affect a message that fits in one packet either way,
and it did not move, which is what says the 4 MB improvement really came from the MTU and not
from drift between runs.

Small-message latency is 1.81 us typical with a standard deviation of 0.00 and a 99.9th
percentile of 2.20 us. That is a clean fabric, not a marginal one.

**The conclusion that matters for the design.** 5843 MiB/s is 49.0 Gb/s on a 50 Gb link, so the
transport is running at about 98% of line rate and there is essentially nothing left to win in
the wire. Every microsecond still on the table is in what happens after the bytes land. ~~That is
precisely what the `cudaHostAlloc` design changes, and it is why the 10.94 us registration
penalty from 7c, measured at a 4 MB payload, is worth chasing even though it is small next to a
695 us transfer for the same 4 MB: DAQiri pays the same 695 us, so the comparison stays honest
and the 10.94 us is the part we actually control.~~ **Second sentence struck 2026-08-21.** The
fabric conclusion stands. The design conclusion does not: 7g shows the registration penalty
needs a CPU producer write, and 7h measured both allocations in this receiver at 4 MB and found
no difference. There is still essentially nothing left to win in the wire, but the thing that
was going to be won after the bytes land was not there.

### RESUME STEP: the PXI RoCE address does not survive a reboot

`enp117s0` on the PXI gets no DHCP lease and comes up with a link-local `169.254.x` address
only, which cannot reach the Spark's `192.168.20.1`. After any PXI reboot, run this as root on
the PXI before anything RDMA will work:

```sh
ip addr add 192.168.20.2/24 dev enp117s0
ip link set dev enp117s0 mtu 9000
```

Both lines are needed and both are lost on reboot. The MTU one matters because the PXI comes up
at 1500, which gives a RoCE `active_mtu` of 1024 while the Spark sits at 4096, and a queue pair
silently negotiates the minimum. Nothing errors; you just quietly lose about 5% of your
bandwidth.

Remove them with `ip addr del 192.168.20.2/24 dev enp117s0` and `ip link set dev enp117s0 mtu
1500`. Verify with `ping -c 3 -I enp117s0 192.168.20.1`, which should show sub-millisecond
replies and 0% loss.

After the MTU change, confirm it actually took effect on both sides rather than assuming it.
Run `ibv_devinfo -d rocep117s0` on the PXI and `ibv_devinfo -d rocep1s0f0` on the Spark and
check that `active_mtu` reads `4096 (5)` in both. Then send a large frame that is not allowed to
fragment, `ping -c 3 -M do -s 8972 192.168.20.2` from the Spark. Note that the PXI's busybox
`ping` has no `-M` flag, so this test has to run from the Spark side. If the two ends disagree
on MTU, large frames black-hole and present as intermittent stalls rather than clean errors,
which is a much worse failure to debug than a refused packet.

The GID index changes when you add the address. On the PXI, RoCE v2 over IPv4 for
`192.168.20.2` is **GID index 5**; on the Spark, RoCE v2 over IPv4 for `192.168.20.1` is **GID
index 3**. Pass these to perftest with `-x`. Read them back with
`cat /sys/class/infiniband/<dev>/ports/1/gid_attrs/types/<i>` alongside `.../gids/<i>` rather
than guessing, because the indices shift as addresses come and go.

Check the address is unclaimed before assigning it: ping it from the Spark and then read
`ip neigh show dev enp1s0f0np0`. An `INCOMPLETE` entry means the Spark asked and nobody
answered, which is a stronger proof of absence than a silent ping.

There is precedent for writing this down. `192.168.20.1` on the Spark was configured ad hoc
during the earlier RoCE work and also did not survive, and rediscovering that cost time. The
symptom is a dead link that looks like a hardware fault and is actually a missing line.

### Topology, established without any privileges

The two 50 G ports go through a switch, not a direct cable. Reading
`/sys/class/net/*/statistics/rx_packets` on the Spark before and after an ARP burst from the
PXI showed `enp1s0f0np0` up 71 and `enP2p1s0f0np0` up 64, while the 1 G ports barely moved.
Both 50 G ports seeing the same broadcasts means one L2 domain. This is a useful trick when you
have no root and cannot run tcpdump.

### Tooling notes for the PXI

We are uid 0 on the PXI, unlike the Spark. `perftest` is not installed there, but `rdma-core`
51.0 with `rdma-core-dev`, `gcc` and `g++` are, so perftest builds from source into a user
directory without touching opkg on a shared instrument controller. `rping`, `ucmatose` and
`udaddy` are present on both ends but only prove connectivity; none of them gives a latency
floor. `ibdev2netdev` is missing on the PXI, so use `ibv_devinfo`.

**How perftest was built on the PXI**, since it is not obvious and took two dead ends.
`configure` hard-fails with "pciutils header files not found" and there is no flag to skip it;
the check is in `configure.ac` and older tags fail the same way, so downgrading does not help.
The box has `libpciaccess` but not `libpci`. perftest uses libpci in exactly one place,
`src/perftest_parameters.c`, to detect PCIe relaxed ordering. Stubbing it out is tempting and is
the wrong call, because relaxed ordering affects RDMA write performance and that is the thing
being measured. Build libpci into a user directory instead:

```sh
cd /home/admin
git clone --depth 1 https://github.com/pciutils/pciutils.git pciutils-src
cd pciutils-src
make -j4 ZLIB=no HWDB=no LIBKMOD=no DNS=no SHARED=no PREFIX=/home/admin/pciutils-inst
make install-lib PREFIX=/home/admin/pciutils-inst

cd /home/admin
git clone --depth 1 https://github.com/linux-rdma/perftest.git
cd perftest
./autogen.sh
./configure CPPFLAGS=-I/home/admin/pciutils-inst/include LDFLAGS=-L/home/admin/pciutils-inst/lib
make -j4
```

Binaries land in `/home/admin/perftest/` and nothing is installed system-wide. The run confirms
it worked: perftest prints `PCIe relax order: OFF`, which is a real detected value rather than a
stubbed default.

`/home/admin` on the PXI already contains `easyrdma`, a built `easyrdma_pingpong` and its
source, plus `grpc-direct` and `bench_pxi`. easyrdma is the library the real transport would
use, so that binary is worth reading before writing new RDMA code.

### How to re-run Gate 3

Server on the Spark, client on the PXI, matching the direction of the real design:

```sh
# on the Spark
ib_write_lat -d rocep1s0f0 -x 3 -s 4194304 -n 1000

# on the PXI
/home/admin/perftest/ib_write_lat -d rocep117s0 -x 5 -s 4194304 -n 1000 192.168.20.1
```

Swap `ib_write_lat` for `ib_write_bw` for the bandwidth figure. The control connection is plain
TCP on port 18515 to `192.168.20.1`; `ufw` is active on the Spark but does not block it.

One trap worth naming. Do not put a `pkill` for the server in the same remote command as the
server launch. The usual `pkill -f "[i]b_write_lat"` bracket trick relies on the quotes
surviving, and when the command is sent through PowerShell the inner double quotes are stripped,
so the pattern matches the shell running the command and kills it. The symptom is a remote
command that produces no output at all, not even an `echo` that ran before the `pkill`.

## 7e. Phase 1: no allocation or registration flag closes the gap (2026-08-19)

> **Read with 7g.** The arms and the sign tests here stand. What does not stand is the framing:
> this section assumes the gap is the thing to close and that closing it is what the transport
> work buys. 7g shows the gap needs a CPU producer write, and the transport does not have one.
> "No flag closes it" is still true and no longer implies "so we must own the allocation".

Section 7c left two cheap questions open before committing to an RDMA transport: whether the
registration penalty is inherent to `cudaHostRegister` or just to the flag we happened to pass,
and whether a page-rounded registration span removes it. Both are one-line fixes if they work,
and both would make the transport work unnecessary, so they run first.

The ladder holds the mapping constant and varies only the flag. Every registration arm gets a
byte-identical `/dev/shm` mapping of its own, so the comparison is controlled rather than four
separate experiments sharing a name.

9 sizes x 8 arms x 5 reps x 200 iterations, arms rotated per iteration, `data/memsrc_flags.csv`,
SHA `6070ae1`. Totals in microseconds, median over reps:

| KB | `hostalloc` | `ha_def` | `ha_wc` | `ha_wcmap` | `shmreg` | `shmreg_def` | `shmreg_port` | `shmreg_big` |
|---|---|---|---|---|---|---|---|---|
| 256 | 19.70 | 19.65 | 19.65 | 19.65 | 27.76 | 27.74 | 28.02 | 27.68 |
| 1024 | 34.19 | 35.01 | 34.32 | 34.16 | 57.55 | 54.75 | 57.65 | 59.23 |
| 4096 | **113.30** | 113.92 | 113.46 | 112.99 | **162.03** | 165.55 | 162.86 | 166.43 |

Read as a fraction of the `shmreg`-to-`hostalloc` gap that each variant closes: every
allocation-side arm is at 94-101% at every size, and every registration-side arm is within
noise of 0%, going negative as often as positive. `shmreg`, `shmreg_def`, `shmreg_port` and
`shmreg_big` are each 0/5 faster than `hostalloc` at every size from 32 KB up; pooled that is
3-4 wins out of 45, p between 9e-10 and 9e-09.

`cudaHostRegisterReadOnly` never ran. The driver refuses it with "operation not supported",
which is the same refusal E4 hit, now confirmed on a second code path.

**Verdict: the decision rule's third branch. Nothing moves, so registration versus driver
allocation is irreducible, the ownership problem in section 7 is real, and owning the
allocation is the only route left.** Phase 2 proceeds with a stronger justification than it
had, because the cheap alternative has now been ruled out by measurement rather than assumed
away.

### Two things this run corrected

**WriteCombined refutes the cacheability story, and it is the cleanest negative here.** 7c
argued that registration must be changing the page's cacheability, since nothing else explains
why it would slow a CPU store. If that is the mechanism, changing cacheability on the
allocation side should move the number. It does not. `ha_wc` and `ha_wcmap` are backed by
`/dev/nvidiactl` with vmflags `rd wr sh mr mw me ms de dd mm`, while `hostalloc` and `ha_def`
are backed by `/dev/zero (deleted)` with vmflags `rd wr sh mr mw me ms`. A different device, a
different driver path, three extra vmflags, and the totals agree to within 0.5 us at 4 MB. So
whatever `cudaHostRegister` costs, plain CPU-side write-combining is not it, and 7c's proposed
mechanism should be treated as unproven rather than established.

**The transform penalty is the smaller half, and it is size-dependent.** 7c measured at 4 MB
only and reported 10.94 us of transform time. Across the ladder the split at 4 MB is +33.86 us
on the write and +14.94 us on the transform, and the transform penalty is absent below about
1 MB: at 128, 256 and 512 KB `shmreg` transforms marginally *faster* than `hostalloc` while
still losing 4-15 us on the write. ~~This does not change the conclusion, because the producer's
write sits outside the measured window in both pipeline arms, so only the transform half is
charged to the headline number, and 14.94 us alone still exceeds the 8.10 us gap.~~ It does mean
any future statement of this effect has to name a payload size.

> **Amended 2026-08-21.** The struck sentence is the one that carried the claim furthest and it
> contains the error in miniature. The producer's write sits outside the measured window, so it
> was dismissed as not counting. 7g shows the write is not a separate cost that can be set
> aside, it is the *cause* of the transform penalty: remove it and registered memory transforms
> 11.25 us faster instead of slower. A term you exclude from the window can still be the reason
> the rest of the window looks the way it does. Note also that this section's own finding, that
> `shmreg` transforms marginally faster than `hostalloc` below 1 MB, is the same sign inversion
> showing up two days early in a size sweep, and it was written down and read past.

`shmreg_big` is null a second time, now under the write-then-transform discipline that 7c said
the original `--zc-bigreg` result lacked. It is 0/5 at every size and slightly the worst arm on
the page at 4 MB. Registration span granularity is closed.

### A bug in the analysis script, found by this run

`scripts/memsrc_table.py` summed only the upper tail of the sign test, from k to n. That is
correct when an arm wins everything and silently wrong when it loses everything: 0 wins out of
45 came out as p = 1, which reads as "no effect" for what is in fact the strongest effect in
the table. Fixed to take the smaller tail, so consistently slower is as detectable as
consistently faster. Every previously reported p-value from this script was for an arm that
won, where the two formulas agree, so nothing already in this document changes.

The same script now prints sign tests per size before pooling them, and on the total rather
than the transform. Pooling is only valid where the effect exists at every size, and the
transform penalty does not exist below 1 MB, so pooling it diluted a real 15 us effect at 4 MB
against eight sizes with nothing to find.

## 7f. Phase 2: the RDMA data path works, and the checker was validated first (2026-08-19)

The smallest program that exercises the architecture end to end. The PXI RDMA-writes into a
`cudaHostAlloc`'d pool on the Spark and cuFFT transforms those bytes in place. No gRPC, no
iceoryx2, no protobuf. `rdma/rdma_fft_server.cu` on the Spark, `rdma/rdma_fft_client.cc` on the
PXI, contract shared through `rdma/rdma_contract.h`.

This is the first time in this project that a measured pipeline has actually crossed the cable.
Section 5 explains why that sentence needed writing.

### The broken-ordering test ran first, and it had to

A verification that always passes is indistinguishable from a verification that cannot see what
it claims to check. So before trusting any green run, `--break-ordering` deliberately launches
cuFFT *before* observing the completion, while the RDMA write is still in flight:

| size | messages | verified | failed | worst peak seen |
|---|---|---|---|---|
| 16 KB | 20 | 1 | 19 | 399902 Hz, expected 10000 |
| 256 KB | 20 | 0 | 20 | 399994 Hz, expected 10000 |
| 4096 KB | 20 | 0 | 20 | 400000 Hz, expected 10000 |

59 of 60 failed and the observed peak is the 400 kHz poison tone, so the diagnosis is
"the transform read the slot before the data landed" rather than a vaguely wrong number.
**The checker is sensitive to the race. Only now do the passing runs mean anything.**

Two design choices are what make this test capable of failing at all, and both are easy to
leave out:

* **The payload changes every message.** The tone is a function of the sequence number. With a
  fixed payload, reading the previous message's leftover bytes would verify clean and the race
  would be invisible.
* **The slot is poisoned before every message,** with a real tone at a frequency no payload
  uses. Without poison the first test above is only checking for stale data, not for absent
  data.

**One result in that table is a warning, not a footnote.** At 16 KB, one message in twenty
verified clean *with the ordering deliberately broken*, because a 16 KB write can land inside
the launch window. The sensitivity of this test is itself size-dependent, and a single-message
version of it at a small payload would have reported all-clear on a program with the race fully
present. Anyone re-running it needs enough messages at the smallest size to make that
vanishingly unlikely; 20 was sufficient, 1 would not have been.

### The correct-ordering run

The rule the program is built around: **the thread that observes the completion is the thread
that launches cuFFT, and the launch follows the observation.** One thread, two adjacent
statements, commented, so that any future edit separating them shows up in a diff.

| run | sizes | messages | verified | failed | CQ errors | timeouts |
|---|---|---|---|---|---|---|
| sweep | 16 KB to 4 MB, all nine | 200 each | **1800** | 0 | 0 | 0 |
| soak | 16, 256, 4096 KB | 10000 each | **30000** | 0 | 0 | 0 |

The sweep covers the full ladder rather than only 4 MB, because 7e found the allocator penalty
is size-dependent. If the RDMA path behaved differently at small payloads we wanted it in the
correctness test rather than as a surprise in Phase 4.

### Nothing on the hot path, asserted rather than intended

`1 alloc, 1 reg_mr, 4 translate` at startup, and the same three numbers at the end of all
31,800 messages. This is enforced, not hoped for: after startup the counters freeze, any
`cudaHostAlloc`, `ibv_reg_mr` or `cudaHostGetDevicePointer` call after that point aborts at the
call site, and a per-message assertion re-checks the totals in case something bypassed the
wrappers. Per-message registration is the single easiest way to build a transport slower than
the one we already have.

Also confirmed at runtime: `host == device VA`, so the cached translation is an identity on this
part. It is still cached rather than assumed, because that is a GB10 property and not a
portable one.

### What this does not show

It is a lockstep correctness harness, one message in flight, with a TCP credit between messages.
**Do not quote any timing from it.** The determinism is what makes the ordering test meaningful,
and it is the opposite of what a latency benchmark wants.

The ordering test also demonstrates sensitivity to data that is absent, which is the loud form
of the race. A subtly partial arrival, where most of the buffer is correct and a tail is not, is
harder to force deliberately and is not separately proven here.

## 7g. RETRACTION: the 10.94 us belongs to the CPU write, not to the memory (2026-08-21)

This is the section that narrows 7c. Read it before quoting 7c or 7e anywhere.

### What prompted it

7h measured the two buffer provenances against each other inside the real RDMA receiver at
4 MB and found nothing: 0.5 us with the sign changing between reps, against a 7c prediction of
10.94 us at the same payload size. Two results about the same mechanism cannot both be right,
so the harness got rerun with the variables crossed instead of held.

### Alignment, which was the wrong guess and is worth recording as one

The first explanation offered was that 7c's arms differed in alignment while the receiver's do
not, since the receiver transforms from `base + kPayloadOffset` at 256 bytes. The second half
is true. The first half is false, and reading the harness would have caught it before the
hypothesis was written down: `fft/bench_fft_memsrc.cc` aligns every arm to 2 MB by
construction, prints `ptr % 2MB` per arm as an audit before timing, and carries a comment
saying alignment had already been a bug once and was not being let back in as a free variable.

It was tested anyway, because holding a variable constant is not the same as testing it and
because 256 bytes is what the receiver really runs at. Four arms, provenance crossed with
alignment, 4 MB, 5 reps, rotated and interleaved, `data/memsrc_2x2_1048576.csv`:

| total us | 2 MB aligned | offset 256 B |
|---|---|---|
| `cudaHostAlloc` | 118.03 | 116.80 |
| mmap + `cudaHostRegister` | 182.51 | 185.50 |

Provenance main effect +66.59 us on the total and +7.31 us on the transform alone. Alignment
main effect +0.88 us on the total, and negative on the transform, meaning the offset arms were
if anything faster. Every registered rep is slower than every `cudaHostAlloc` rep, 5 of 5 on
both columns. **Provenance reproduces. Alignment is not the variable.**

### The variable is the CPU write, and removing it inverts the sign

7c exists because of a methodology fix: the ladder before it never wrote to the buffer and
declared memory kind dead, and adding the write separated the arms by 10.94 us. The read-only
null was filed in section 1 as a burn. So the same four arms were run again with the write
taken back out, `--write off`, everything else identical, `data/memsrc_2x2_nowrite_1048576.csv`:

| transform us | 2 MB aligned | offset 256 B |
|---|---|---|
| `cudaHostAlloc` | 54.69 | 51.71 |
| mmap + `cudaHostRegister` | 42.43 | 41.47 |

With the CPU write, registered memory is 7.31 us slower. Without it, registered memory is
11.25 us faster. 5 of 5 either way, and the spread inside an arm is under a microsecond, so
this is not noise in either direction.

**The 10.94 us is therefore not a property of the memory.** It is a property of the interaction
between the producer's stores and the transform's reads, and `cudaHostRegister` changes that
interaction. 7c named the clue and did not follow it: registration has no business changing CPU
store speed, and it doubles it, which means it is changing the page's cacheability or coherency
attributes. The transform penalty is the other end of the same change.

**So the read-only ladder was not wrong.** It was answering a different question and was retired
for the wrong reason. Both measurements are correct about the configuration they measured. The
error was carrying 7c, measured with a CPU producer writing every buffer, to a receiver where a
NIC writes the buffer and the CPU never touches it.

### What `--write off` is not

It is not a model of DMA arrival and must not be quoted as one. With the write off, the same
bytes are transformed thousands of times running, so the GPU reads a cache-resident buffer,
which no pipeline does. Read that table as a bound. **Nothing in `bench_fft_memsrc` models a DMA
arrival**, which is exactly why 7h had to run on the real receiver, and 7h is the measurement
that stands.

### What survives

- On the **shmem path**, where a CPU producer does write every buffer, driver-allocated pinned
  memory beats allocate-then-register by 7 to 11 us of transform and about 2x on the write, at
  4 MB. 7e shows no flag on either side closes it. This is a statement about the shmem path.
- On the **RDMA path**, there is no measured difference. 7h.
- Owning the allocation may still be worth having, for reasons that never depended on 7c: no
  per-buffer registration, no unregister on teardown, a fixed slot pool, and a
  release-before-completion gate we control. Those are correctness and steady-state arguments,
  not microsecond arguments.

Full write-up, including what it costs the RDMA plan, in `rdma_transport_plan.md` §7.

## 7h. Phase 4, the 4 MB cell: the two provenances in the real receiver (2026-08-20)

Run before the release-before-completion race work rather than after it, because this is the
cell the hypothesis rested on and a timeboxed race that overran would have left a working path
with no evidence it helped.

Three arms, 5 reps, arms rotated within each rep, `scripts/phase4_cell.sh`,
`data/phase4_cell_1048576.csv`. All 15 rows cleared the 2400 MHz clock gate, every RDMA message
was spectrum-verified, and every message sent arrived.

| Arm | e2e p50 (us) | cuFFT p50 (us) | residual (us) | delivered |
|---|---|---|---|---|
| `rdma` (our `cudaHostAlloc` pool) | 72.77, 74.86, 67.54, 76.35, 74.50 | 65.22, 67.20, 59.71, 69.15, 67.14 | 7.55, 7.66, 7.83, 7.20, 7.36 | 6828 / 6828 |
| `rdma-stock-nopoll` (driver buffers) | 71.90, 69.79, 70.90, 73.82, 76.32 | 64.42, 62.53, 63.49, 66.50, 69.06 | 7.49, 7.26, 7.41, 7.33, 7.26 | 6828 / 6828 |
| `base` (shmem, optimizations off) | 659.63, 661.78, 662.77, 664.03, 661.71 | 361.12, 364.03, 363.36, 364.42, 362.43 | 298.51, 297.75, 299.41, 299.62, 299.28 | 11111 / 11111 |

Paired by rep, `rdma` minus `rdma-stock-nopoll` on e2e p50 is +0.87, +5.07, -3.36, +2.53,
-1.82 us. Three of five in one direction, sign test p = 1.0. On the transform alone, three of
five again. On the residual, four of five with a median of +0.10 us, p = 0.375. **The two
provenances are indistinguishable.**

**Do not quote the gap to `base` as a transport result.** `base`'s own log reads
`feed mode: realign via D2D`, `realigns: 11111`, `not 16B aligned`. It copies 4 MB
device-to-device inside the measured window because the shmem proto store lands 8-byte aligned
and `--no-zc-align` disables the fix. That is what `base` means. It shows in both halves: a
361 us transform for the same FFT the RDMA arms do in 65 us, and a 299 us residual against
7.4 us. Most of the 9x is the deliberately disabled optimization. **`opt` is now back in the
Phase 4 arm list** and is the arm any transport claim gets made against; `base` stays only as
the standing reference.

Back-pressure behaved as designed: the RDMA arms lost nothing and paid 1.9 to 2.3 seconds
blocked in the sender against a 686 us wire time. Shmem at 4 MB also lost nothing, unlike at
16 KB where it drops 14 percent paced and 71 percent unpaced. Delivered count and blocked-send
time are separate columns and must never be combined.

> **The blocked-send figure in that last paragraph is contaminated, and 7i explains how.**
> This cell ran with `--verify every`, which puts a spectral peak search between the transform
> and the slot re-queue. The sender was blocked because the receiver was verifying, not because
> the fabric was busy. The e2e and cuFFT columns above are unaffected, because they stop before
> the verify begins, so the two-provenance result stands. **The throughput and back-pressure
> figures from this cell are not representative of the path and should not be quoted.**

## 7i. The transport was never being measured, and the sender's stall was ours (2026-08-21)

Every latency number this project produced before today starts its clock **after** the data has
landed. That was deliberate and it was labelled honestly, because the question at the time was
where the GPU's time goes. It was never revisited when the question changed to why DAQiri is
faster, and by then the window being reported was a small slice of the pipeline it was being
read as.

| Benchmark | `e2e` timer starts | measures the wire |
|---|---|---|
| `rdma/extbuf_fft_server.cu` | after `grpc_direct_server_receive_ext()` returns | no |
| `daqiri/bench_daqiri_pipeline.cc` | after the burst is parsed | no, `wire_latency_us` is hardcoded 0 |
| `daqiri/bench_daqiri_roce_pipeline.cc` | after the RDMA completion | no |
| `grpc_direct/bench_grpc_server.cc` | after `reader->Read()` | yes, line 232, via `send_timestamp_ns` |

Two other things fell out of the same audit and should be recorded before they are rediscovered.
The cuFFT **output** goes to `cudaMalloc`'d device memory in all four benchmarks with no
device-to-host copy anywhere, inside or outside the timed region, so that hypothesis is closed
negative. The cuFFT **input** does not: the extbuf receiver transforms `cudaHostAlloc(Mapped)`
host memory, while the gRPC and DAQiri paths transform `cudaMalloc`'d device memory after a
host-to-device copy. `fft_p50` is therefore not the same operation across paths and must not be
compared across them without saying so. Both DAQiri benchmarks are also **single-process
loopback**, both endpoints on the same address, while the extbuf RDMA arm is genuinely
cross-machine, so the headline comparison has been loopback against wire.

### The instruments

Two of them, for two different quantities, from two different runs. `scripts/transport_cell.sh`
drives both. They must not appear in the same table row.

**Echo, on the sender's clock alone.** The PXI timestamps before it posts, the Spark transforms
and replies with a 16-byte ack, the PXI timestamps the reply. This cannot be done by
differencing wall clocks: the PXI's realtime clock is **23.13 seconds ahead** of the Spark's,
measured by round trip, and neither box runs NTP or chrony. The ack is sent immediately after
the transform's gate and before anything else, so any instruction placed above it would be
charged to the transport. `--echo on` **refuses to start** with `--poison on` or
`--verify every`, because both sit between the gate and the ack and would land inside the
interval the sender is timing. Refused rather than warned about, since a warning in a log is a
warning nobody reads before quoting the number.

**Inter-arrival, on the receiver's clock alone**, from a separate streaming run, reported next
to the sustained rate and the consumer duty cycle so the three are read together.

### Result 1: post to FFT-complete, 4 MiB

The calibration arm runs the same round trip with `--fft off` at 64 points, so it measures the
request-and-return path with no work in the middle. Subtracted paired per rep.

| rep | echo rtt p50 (us) | calibration rtt p50 (us) | difference (us) |
|---|---|---|---|
| 1 | 1379.05 | 109.39 | 1269.7 |
| 2 | 1438.43 | 23.47 | 1415.0 |
| 3 | 1390.98 | 26.76 | 1364.2 |

Three of three positive. Median about **1364 us**. `data/transport_cell_1048576_s4.csv`.

**Two caveats, both load-bearing.** First, waiting for the ack serialises the sender, because
the RDMA pending response is a thread-local slot that the next send overwrites. This is
therefore **unloaded latency**, the cost of one message with nothing else in flight, and it is
not the cost per message under load. Throughput has to come from the streaming arm. Second,
**rep 1's calibration is an outlier**, 109 us against 23 and 27, so that row's difference is the
weakest of the three. The other two agree to within 51 us.

The clock starts at the send call, not at frame construction, so the 487 us the sender spends
building the frame is outside this number.

### Result 2: the sender's 2205 us stall was our own verification

Phase 4's 4 MB cell recorded the sender blocked about 2205 us per buffer against a 685 us wire
time. That was read as a fabric or depth problem for weeks. It was neither.

The instrument that found it is `hold_us`, measured on the receiver from the transform's gate
completing to `grpc_direct_server_slot_requeue` returning. `detect_peaks` runs inside that
window. For two and a half milliseconds a slot the NIC could be refilling is sitting in a peak
search, and the sender blocks in `AcquireSendRegion` for exactly that long and reports it as
send time. `rq_us`, the re-queue call itself, is 1 to 8 us throughout and was never a candidate.

Paired per rep, 4 MiB, 1000 measured messages, three reps, arms rotated.
`data/tc_verifycost_1048576_s4.csv`.

| arm | send p50 (us) | hold p50 (us) | gap p50 (us) | MiB/s |
|---|---|---|---|---|
| `stream` (`--verify every`) | 2090.71 | 2488.58 | 2561.85 | 1561 |
| `stream-nv` (`--verify off`) | 340.56 | 11.54 | 812.13 | 4925 |
| `stream` | 2070.10 | 2480.34 | 2553.49 | 1566 |
| `stream-nv` | 331.83 | 12.05 | 776.45 | 5149 |
| `stream` | 2250.71 | 2666.04 | 2743.11 | 1458 |
| `stream-nv` | 345.44 | 13.71 | 820.58 | 4875 |

Three of three, no overlap between the arms, **3.18x on the median**. 4983 MiB/s against the
5843 MiB/s Gate 3 measured with `ib_write_lat`, so **85 percent of the link where it had been
27 percent**.

`rdma/extbuf_fft_server.cu` already carried the comment that verification belongs outside the
credit window and that Phase 4 should run with `--verify off`. `scripts/phase4_cell.sh:193`
passed `--verify every`. The two files disagreed in the repository for a month and nothing
reconciled them, which is why the server now refuses the combination outright rather than
relying on the caller to remember. **Every throughput and blocked-send figure from the Phase 4
cell is contaminated by this and should not be quoted.** The latency columns from that cell are
not, because they stop at the gate.

### Result 3: slot depth is innocent, closed by measurement

`stream-nv` at 2, 4, 8 and 16 slots, three reps each. `data/transport_cell_1048576_s{2,4,8,16}.csv`.

| slots | MiB/s |
|---|---|
| 2 | 4785, 5030, 4975 |
| 4 | 4925, 5149, 4875 |
| 8 | 5017, 4986, 5009 |
| 16 | 5027, 4942, 4977 |

One distribution. Depth was the most attractive of the four candidates because it would have
been a one-line fix with a large effect, and it is worth recording that it was wrong. Two slots
is enough, which also means the release-before-completion race matters at the depth the pipeline
actually needs.

### Result 4: what bounds it now is the sender's CPU

`gen_p50` 468 us plus `send_p50` 335 us is 803 us of single-threaded host memcpy against a
`gap_p50` of 800 us. There is no time left over for anything else to be the bottleneck. The PXI
copies 4 MiB **twice** per message: once in `extbuf_fft_client.cc` building the frame, and once
inside `grpc_direct_client_send`, which copies the frame into the send region. About 10 GB/s
each, which is an ordinary single-threaded memcpy rate.

This matters for how the result is framed. **The receive path sustains 85 percent of line rate,
and what limits the run is a synthetic sender doing work a real digitizer would not do**, namely
manufacturing a waveform in host memory and then handing it to a library that copies it again.
That framing is worth confirming by measurement rather than asserting, which is the next
experiment.

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
sudo.** Repo at `/home/nitest/daqiri_gpu`, build dir `build_grpc/`. The repo there is an scp
mirror with **no git metadata**, so always pass `GITSHA=` explicitly to any script that stamps
it.

**Second machine, for the RDMA work.** NI PXIe-8881 `NI-PXIe-8881-31F6D74`, ssh alias `pxi`,
10.198.65.118, NI Linux Real-Time, kernel 6.12.74-rt16, x86_64. **We are uid 0 there**, unlike
on the Spark. RoCE device `rocep117s0` on netdev `enp117s0`, cabled through a switch to the
Spark's `enp1s0f0np0` / `rocep1s0f0`. Addresses `192.168.20.2` and `192.168.20.1`. See 7d for
the two commands that must be re-run after any PXI reboot, and for the perftest build at
`/home/admin/perftest`. ICMP is blocked on the corporate network but works fine on the
192.168.20.0/24 RoCE segment.

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
- **PowerShell strips inner double quotes from a single-quoted ssh argument.** `grep -aE "A|B"`
  arrives split in two and the remote shell reports "command not found"; `echo "(text)"` becomes
  `echo (text)` and dies with a syntax error before anything runs. Use `grep -a -e A -e B`, and
  **never put parentheses or double quotes inside a remote command string.**
- Inline `pkill -f <pattern>` over ssh kills your own remote shell, because the shell's command
  line contains the pattern. The usual `[p]attern` bracket trick does not save you, because the
  quotes around it get stripped too. The symptom is a remote command that produces **no output
  at all**, not even an `echo` that ran before the `pkill`. Use it only from inside a script
  file, and never in the same command as the thing it is guarding.
- **Never use `| Out-String`.** It buffers until the pipeline closes, so a finished command
  looks hung.
- `cmd | tail` makes `$?` report tail's status. Use `${PIPESTATUS[0]}`, or redirect to a file
  and then `echo $?`.
- Long-running ssh commands get moved to a background terminal, and reading that terminal back
  often returns stale scrollback. Redirect remote output to a file and read the file.
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
| `fft/bench_fft_memsrc.cc` | The memory placement ladder, and the harness behind both the 10.94 us at 4 MB result and its retraction in 7g. `--write off` removes the producer's CPU write, which inverts the sign. `--offset-bytes` moves the offset arms off their 2 MB boundary. No gRPC, no DAQiri, no network. Build target `bench_fft_memsrc`. |
| `scripts/memsrc_table.py` | Local. Turns its CSV into write / transform / total tables, paired sign tests, and a `shmreg` versus `hostalloc` head-to-head. |
| `scripts/gate1_caps.cu`, `scripts/gate4_regmr.cu` | The RDMA gates. Self-contained, run on the Spark, print their own verdicts. |
| `scripts/grpc_sweep.sh`, `scripts/roce_sweep.sh` | Older single-transport sweeps. **Not interleaved with each other.** Use `headline_sweep.sh` for any gRPC-vs-DAQiri claim. |

## 10. What to do next

The question that used to head this list, "why is our cuFFT slower than DAQiri's", is answered,
and the answer that replaced it has since been narrowed. It is not cuFFT. On the **shmem path**,
it is the buffer cuFFT is reading: at 4 MB, driver-allocated memory transforms 7 to 11 us faster
than memory we allocate and register ourselves. That penalty needs a CPU producer writing the
buffer, it shrinks with payload size and vanishes below about 1 MB, and it **does not exist on
the RDMA path**, where a NIC writes the buffer and the CPU never does. Sections 7c, 7e, 7g, 7h.
Size and producer are both part of the claim now.

Items 1 to 3 below are struck. They were the follow-ups to a mechanism whose scope has changed,
and two of the three were answered as part of narrowing it. They are left visible because the
list they came from is what a reader would otherwise reconstruct.

1. ~~**Is the penalty inherent to `cudaHostRegister`, or to how we call it?**~~ **Answered, 7e:
   no flag on either side closes any measurable part of it.** The note that the CPU write is
   also about 2x slower on registered memory turned out to be the important part, and 7g
   follows it: registration changes the page's cacheability, the slow write and the slow
   transform are two ends of the same change, and removing the write inverts the sign.
2. ~~**Does registering once at startup remove it?**~~ **Answered, 7e and 7h: no.** The Phase 4
   receiver registers everything during warmup and asserts nothing registers afterwards, and
   there is still no difference between the arms. Warm registration is not the variable.
3. ~~**The warm-versus-cold ring hole.**~~ **Superseded.** 7h runs a real rotating slot pool over
   6828 messages per rep instead of one reused buffer, which is the measurement this item was
   asking for, and it agrees with 7g rather than with 7c.
4. **Finish Phase 4 with `opt` in the arm list.** The 16 KB cell has not been run and the 4 MB
   cell needs re-running with four arms. `scripts/phase4_cell.sh`, `NPTS=4096` and
   `NPTS=1048576`. Note the warmup formula asks for roughly 893,000 messages at 16 KB to reach
   four seconds of traffic, which is legitimate but worth a wall-clock sanity check first.
   **Its throughput columns must be re-collected with `--verify off`; see 7i.**
5. ~~**The release-before-completion race, step 6.**~~ **Dropped by decision, 2026-08-21.** It is
   a correctness property that can be described analytically, and 7i showed the depth arithmetic
   it rested on is the depth the pipeline actually runs at, so the argument is stronger on paper
   than the demonstration would have been with the calendar available. The window arithmetic is
   preserved in the struck text below rather than deleted.

   ~~Demonstrate corruption at 16 KB with 2 slots, where the window arithmetic says it
   reproduces: one arrival is about 4.5 us, so with 2 slots the window is about 9 us against a
   measured ~8 us `fft_p50`. At 4 MB one arrival is 694.76 us and the window is about 1.39 ms,
   so it will not reproduce naturally. Write the 4 MB case up with the arithmetic rather than
   widening the window with artificial GPU work.~~
6. **Generate in place on the sender.** This is the current bottleneck and the highest-value
   experiment left. 7i shows the PXI spends 803 us per 4 MiB message in two host memcpys against
   an 800 us arrival interval, so the sender is the whole limit. Removing one of the two copies
   should move the number a long way. It also decides how the headline is framed: whether the
   85 percent of line rate is bounded by a synthetic sender doing work a digitizer would not do,
   which is currently an assertion rather than a measurement.
7. **DAQiri cross-machine.** Both DAQiri benchmarks are single-process loopback with both
   endpoints on the same address, while the extbuf RDMA arm is genuinely PXI to Spark, so the
   standing comparison is loopback against wire. Fixing it means splitting
   `daqiri/bench_daqiri_roce_pipeline.cc` into real client and server roles, which is real work
   rather than a flag.
8. **Attack the residual floor.** We sit near 5.5 to 6.7 us against DAQiri's 4.9. Worth 0.3 to
   1.7 us, smaller than the above but fully ours. `--opt-stream` took the easy part; what is
   left is per-message CUDA event record/query overhead and metrics bookkeeping. Consider
   whether both events per buffer are needed.

**Deliberately not on this list.** The arena (section 7, blocked at an ownership boundary).
E1/E3/E4 (section 6, measured and rejected). Landing data in device memory (7b and 7d: the
hardware refuses it, `GPU_DIRECT_RDMA_SUPPORTED = 0`, and `ibv_reg_mr` on device memory returns
"Bad address"). Fabric tuning (7d: already at 98% of line rate). Huge pages, NUMA and
registration granularity (7c: all eliminated with evidence). Alignment as an explanation for
the 7c effect (7g: tested and null, and it had already been held constant in 7c).

**On the small-buffer drops, which are benign and can stay deprioritised.** Only 170 to 179 of
200 buffers are delivered at 256 KB and below, which looked like it might bias the medians. It
does not. The missing sequence numbers are all early (roughly 1 to 26, plus a small cluster near
45 to 56) and nothing is lost after about seq 56 in a 250-message run. Every measured window is
contiguous, so we measure ~171 *consecutive* messages instead of 200: a smaller sample, not a
biased one. The decisive evidence that this is a startup transient rather than
latency-correlated shedding is that the 35%-faster arm drops the *same* count as the slow arm
(29 vs 29, 24 vs 23). A ring shedding under backlog would shed less on the faster arm. Loss is
also bursty (mean run length 12 to 14.5, not ~1), raising the pace from 400 to 2000 us cuts it
from 29 to 2, and there are zero drops at 4 MB.

## 11. Open questions

1. ~~Why is `cudaHostRegister`'d heap memory ~10 us slower for a cuFFT read than
   `cudaHostAlloc`'d memory?~~ **Withdrawn, reinstated, answered, then narrowed.** First
   dismissed as thermal drift, correctly, because the original ladder was built from separate
   runs. Rebuilt properly the effect is real: 10.94 us at 4 MB, 15 of 15 paired cells,
   p = 6.1e-05, section 7c. **Narrowed by 7g**: it needs a CPU producer write, and without one
   the sign inverts and registered memory is 11.25 us faster. The question as originally phrased
   has a false premise, since registered memory is not slower in general.
2. ~~Why does our cuFFT run ~4 us slower at 1024 and 2048 KB specifically but match at
   4096 KB?~~ **Dissolved.** There was never anything size-specific. The gap exists at every
   size and the apparent match at 4 MB was itself the artifact. Section 5.
3. **What does `cudaHostRegister` actually change about a page?** Still the live version of
   question 1, and 7g raised its value rather than answering it. Registration makes CPU stores
   about 2x slower and makes a subsequent GPU read of those stores slower, while making a GPU
   read of an untouched buffer *faster*. A cacheability or coherency attribute change is the
   obvious candidate and would explain all three signs at once. Nobody has read it out of the
   system's own accounting yet, which by this project's own rule is what would turn it from a
   story into evidence.
4. Can grpc-direct be made to allocate received messages into a supplied arena? Section 7: the
   answer from this side is no. The question is whether the Rust side wants to expose a seam.
   Note that 7d is the other way of solving the same problem: if we own the transport, we own
   the allocation, and the arena question stops mattering.
5. Is ~52 GB/s expected for the copy engine reading mapped host memory on GB10? An SM kernel
   got ~102 GB/s.
6. Is "cuFFT R2C accepts an 8-byte-aligned input" safe to rely on, or UB that happens to work?
   We probe at runtime and fall back, so we are safe either way, but it would be good to know
   whether the fallback can ever trigger.
7. Can anything be done about the unlockable clocks? Every methodological contortion in
   section 1 exists because of that one missing privilege.

## 12. File map

| File | Role |
|---|---|
| `grpc_direct/bench_grpc_server.cc` | The hot path. `StreamBuffersPerMessage` is the shmem handler; `ShmemSession` holds per-session state; `FinalizeShmemSession` prints the teardown report including the Phase 0 block. |
| `fft/cufft_executor.{h,cu}` | `CuFFTExecutor(n, own_stream)`. With `own_stream` it creates a non-blocking stream, calls `cufftSetStream`, and completes by spinning on `cudaEventQuery` instead of `cudaEventSynchronize`. Also has `try_execute()` (non-throwing, used by the E2 alignment probe) and `launch_realign_copy()` (the E3 kernel). |
| `grpc_direct/bench_grpc_client.cc` | Builds a fresh `BufferRequest` inside the send loop and does a full CPU copy per iteration. Excluded from server e2e but caps throughput. Has `--pace-us` (default 400). |
| `grpc_direct/pipeline_fft.proto` | `samples` is field 1 (`FloatArray`), `raw_samples` is field 4 (`bytes`). |
| `fft/bench_fft_memsrc.cc` | The memory placement ladder. Arms `device` / `devwrite` / `mgdwrite` / `hostalloc` / `heapreg` / `shmreg` / `hugereg`, plus the 7g 2x2 `ha_align` / `ha_off` / `reg_align` / `reg_off`. Has `smaps_backing()` for reading what actually backs a mapping, a `SIGSEGV`/`SIGBUS` fault probe that drops an unusable arm instead of killing the sweep, and a rotating arm order. **`--sizes` is in samples, not KB.** **`--write off` is a cache-resident bound, not a DMA model.** |
| `scripts/gate1_caps.cu`, `scripts/gate4_regmr.cu` | The RDMA feasibility gates. Build with `nvcc -O2 -arch=native ... -lcuda`, and add `-libverbs` for gate 4. |
| `PROGRESS.md` / `SHORTTERM_CONTEXT.md` / `LONGTERM_CONTEXT.md` | Updated, and **now committed** — they were gitignored while being cited here. |

## 13. Benchmark parameters (keep these constant for comparability)

N=200 measured, W=50 warmup, pace 400 us, client `taskset -c 11`, transport shmem,
`--one-shot`. Sizes 4096 to 1048576 samples (16 KB to 4 MB). DAQiri comparison numbers come
from `data/daqiri_roce_{mode}_{size}.csv`, gRPC from `data/grpc_{mode}_{size}.csv`.
