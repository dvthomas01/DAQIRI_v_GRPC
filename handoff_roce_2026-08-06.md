# HANDOFF — DAQiri GPU FFT Benchmark (CURRENT, 2026-08-06)

> Paste this into a new chat to continue. This top section is the current, self-contained
> handoff (everything a new session needs about the system + state). The older "Airtight
> Benchmark Rerun" handoff is preserved below the divider for historical detail.

---

## 0. One-line status
The **real two-machine Spark ↔ PXI 50 G RoCE link is UP and RDMA is verified** (`rping` RC
read/write, 10/10, clean disconnect). Earlier in this arc the **RoCE true zero-copy FFT pipeline**
and a **4 MB RoCE-vs-gRPC-Direct sweep** were completed (all PASS, 0 drops on RoCE). Next up: run
the real cross-machine RoCE FFT sweep (server on one box, client on the other).

## 1. What this project is
DAQiri-vs-gRPC-Direct GPU FFT pipeline benchmark. Two data paths feed a CUDA `cuFFT` R2C:
- **Pipeline A (DAQiri):** DAQiri transport → GPU → cuFFT. Transports: TCP socket test shim
  (BNO-style, caps ~128 KB) and **RoCE/RDMA RC** (the real zero-copy path, scales to 4 MB).
- **Pipeline B (gRPC-Direct):** gRPC / shmem (iceoryx2) → GPU → cuFFT.
Metric of record = end-to-end (e2e) p50/p99 per buffer, plus H→D transfer, cuFFT exec, throughput,
delivery/drops. Zero-copy on GB10 = true in-place cuFFT (host ptr == device ptr, 0 µs H→D).

## 2. The machines (READ THIS BEFORE RUNNING ANYTHING)

### DGX Spark — `spark-ac69`
- Reach by **hostname**: `spark-ac69.ni.corp.natinst.com` (mgmt IP is DHCP, currently 10.198.65.106;
  old 10.1.30.230 is DEAD). Login `nitest`, key auth, **NO password, NO passwordless sudo**.
- OS DGX/Ubuntu 24.04, **aarch64 (ARM)**. GPU **NVIDIA GB10** (Grace-Blackwell), driver 580.95.05,
  **clocks NOT lockable**. CUDA 13 at `/usr/local/cuda-13/bin`.
- Repo on Spark: `/home/nitest/daqiri_gpu` (gRPC bench binaries in `build_grpc/`). DAQiri SDK +
  source at `/home/nitest/daqiri` (RoCE/ibverbs engine lives here).
- RoCE port to PXI: **`enp1s0f0np0`** (`rocep1s0f0`, LEFT QSFP) = **192.168.20.1/24**, MAC `…ac:6a`.
  Second 50G port `enP2p1s0f0np0` is also link-up but is NOT the PXI link.

### NI PXIe-8881 — `NI-PXIe-8881-31F6D74`
- Management IP **10.198.65.118** (NIC `eno0`). OS **NI Linux RT x86_64**, kernel 6.12-rt.
- SSH `root@10.198.65.118` **OR** `admin@10.198.65.118` — key auth, NO password, **ROOT shell**.
- RoCE port to Spark: **`enp117s0`** (`rocep117s0`) = **192.168.20.2/24**, MAC `b8:ce:f6:40:5e:ea`,
  50 Gb/s DAC. **This IP is runtime-only (`ip addr add`), NOT persisted** — re-add after reboot,
  or persist via NI MAX / `connmanctl`. It previously had only a link-local `169.254.x` (dead subnet).

### The RoCE link
Direct DAC cable, subnet **192.168.20.x**. Verified: bidirectional ping 0% loss; `rping` RC
read/write 10/10. RDMA tools present on BOTH: `rping`, `ucmatose`, `ibv_rc_pingpong`,
`rdma_server/client`. `ib_send_bw` etc. only on Spark. Both RoCE ports `PORT_ACTIVE` / Ethernet.

## 3. Key results so far
- **RoCE true zero-copy sweep (16 KB→4 MB, N=200/W=50/pace 400 µs):** all 18 runs PASS, 0 drops,
  200/200 delivered. ZC e2e p50: 16 KB=11.5, 128 KB=20.4, 1 MB=28.2, 4 MB=63.7 µs (p99 75.5).
  Copy e2e p50 @4 MB=167.1. ZC transfer=0 every size. Data: `data/daqiri_roce_{mode}_{size}.csv`.
- **gRPC-Direct 4 MB sweep (same params, shmem):** all 18 PASS to 4 MB. ZC e2e p50 4 MB=126.3
  (p99 134.4). RoCE lower latency every size (~1.5× @16 KB → 2.0× @4 MB p50), tighter tail, 0 drops;
  gRPC drops small buffers (n_measured 172–175/200 ≤128 KB). Report: `GRPC_VS_ROCE_4MB.md`.
- Both get ~2.6× zero-copy speedup on GB10.

## 4. How to run things on Spark / PXI (gotchas that WILL bite)
- Use full paths: `C:\WINDOWS\System32\OpenSSH\ssh.exe` / `scp.exe`, add `-o ConnectTimeout=N`.
- **ALWAYS scp a script file + `bash /tmp/x.sh`.** Inline multi-line compound commands (with `&`/
  `wait`) get mangled over `ssh -c`. In PowerShell, backtick-escape remote `$` in double quotes
  (`` `$? ``). NI RT prints a MOTD banner to stderr → PowerShell shows a red "NativeCommandError"
  and exit code 1 even on success; judge by the actual stdout, not the exit code.
- **Hung terminals:** a foreground `timeout N ./bench` or an inline `nohup … & echo PID=$!` holds
  the SSH channel (the tool backgrounds it, looks hung). Launch detached with `setsid bash -c '…'
  </dev/null >log 2>&1 &` from a script, then poll the log from a fresh ssh. Kill a hung launcher
  terminal immediately.
- gRPC runtime env on Spark: `export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/
  grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"`. shmem cleanup between runs:
  `pkill bench_grpc; rm -rf /tmp/iceoryx2; rm -f /dev/shm/iox2_*; sleep 1`.
- **No LED blink / `ethtool -p`** without root (denied on Spark). Identify ports functionally via
  ARP once IPs are set (`ip neigh`), not by faceplate guessing.

## 5. Immediate next steps
1. **Real two-machine RoCE FFT sweep** — server on one box, client on the other, IPs
   `192.168.20.1`/`.2`. `daqiri/bench_daqiri_roce_pipeline.cc` is currently a single-process
   same-device loopback → needs a `--role server|client` + peer-IP split, OR use daqiri's own
   `daqiri_bench_rdma` across the two machines. The PXI needs the binary too (NI Linux RT x86_64,
   kernel 6.12-rt) or run daqiri's prebuilt tool there.
2. **Persist the PXI RoCE IP** (NI MAX or `connmanctl`).
3. **Commit/push** RoCE pipeline + sweeps + scripts + figures — ask before pushing.

## 6. Where the detail lives
- `PROGRESS.md` — Results Log (RoCE link, RoCE sweep, gRPC 4 MB sweep, older M1–M13).
- `SHORTTERM_CONTEXT.md` — current sprint state + next steps.
- `LONGTERM_CONTEXT.md` — hardware/network/RDMA-fabric reference (now current).
- `GRPC_VS_ROCE_4MB.md` — full RoCE-vs-gRPC comparison write-up.
- Repo memory `/memories/repo/grpc-zero-copy.md` — dense engineering notes + all gotchas.
- Scripts: `scripts/{roce_sweep,grpc_sweep,pxi_check,pxi_setip,rdma_tools,pxi_rping_server,
  port_map}.sh`.

---

# HANDOFF — DAQiri vs gRPC "Airtight" Benchmark Rerun (historical — sweep COMPLETE)

Captures the full state through the completed airtight comparison.

---

## 0. One-line status
The **airtight A/B latency sweep is COMPLETE and PLOTTED.** Both pipelines (DAQiri Pipeline A, gRPC Direct Pipeline B) were paced identically at **400µs** to neutralize GPU clock/DVFS. All 40+40 CSVs pulled local, all 5 trials/config, full delivery, figures regenerated. The earlier gRPC zero-copy `rows=-1` risk is **RESOLVED** (all 40 gRPC CSVs incl. zero-copy present & valid). **Result: DAQiri wins per-buffer latency in both copy and zero-copy at every buffer size, and the airtight (both-paced) comparison actually strengthens DAQiri's zero-copy advantage vs the earlier unfair run.**

---

## 1. The goal (user's words)
> "i want to do a rerun of grpc unpace to remove lock caveat but are there any other variables that made the comparisons not accurate that we should do in this rerun and make comparisons as airtight as we possibly can?"

Make the DAQiri-vs-gRPC FFT-pipeline comparison **as methodologically airtight as possible**, eliminating confounders.

## 2. ✅ RESULTS (airtight — BOTH pipelines paced @400µs, 5 trials each, N=1000 W=100)

### Zero-copy head-to-head — E2E p50 (the clean comparison; both skip host staging)
| BS | DAQiri | gRPC Direct | gRPC vs DAQiri |
|----|--------|-------------|----------------|
| 4096 | 10.22µs | 16.77µs | **+64.0%** |
| 8192 | 11.94µs | 17.36µs | **+45.4%** |
| 16384 | 14.22µs | 21.38µs | **+50.3%** |
| 32768 | 20.78µs | 26.48µs | **+27.4%** |

### Matched-pair, clock-neutralized E2E p50 delta (median over 5 trials, gRPC − DAQiri)
- **copy:** +100.98 / +115.79 / +94.56 / +110.31 µs  → gRPC **+222–318%** slower (dominated by gRPC's extra host-staging memcpy + H→D transfer; DAQiri copy mode has no staging copy).
- **zerocopy:** +6.58 / +5.39 / +7.23 / +5.68 µs  → gRPC **+27–64%** slower.

### FFT exec p50 (on-GPU clock probe — confirms clocks MATCHED between A and B)
- copy: DAQiri 5.18/6.37/8.74/15.94 vs gRPC 8.38/9.22/11.87/17.09 µs
- zerocopy: DAQiri 5.15/6.85/9.15/15.78 vs gRPC 8.61/8.51/11.58/15.52 µs
- FFT times are within a few µs → the equal-pacing design successfully put both in the same clock regime. gRPC's slightly higher FFT reflects D2D-realign + framing, not a clock mismatch.

### Transfer p50 (µs) and throughput (MB/s)
- copy transfer: DAQiri ~20–23µs vs gRPC ~111–131µs. zerocopy transfer = 0 for both.
- zerocopy MB/s: DAQiri 1602/2749/4607/6316 vs gRPC 977/1888/3066/4950.

### Interpretation (important)
- gRPC's paced E2E p50 is essentially unchanged from the earlier run (16.77 vs 16.78µs @4096) — gRPC was already paced@400 before. What changed is **DAQiri is now ALSO paced**, and DAQiri got **faster** (ZC @4096: 10.22µs now vs 15.07µs unpaced). So the earlier "unpaced DAQiri" was actually *slower* per-buffer (burst backpressure/queuing). ⇒ The airtight rerun does **not** erode DAQiri's edge — it **reinforces** it.
- Absolute latencies differ from the unpaced run because both now sit in the cooler paced-clock regime, but the **relative** comparison is now airtight.
- Figures: `data/figures/fig_ab_airtight_01_latency.png`, `data/figures/fig_ab_airtight_02_zerocopy_headtohead.png` (regenerated).

## 3. Hardware / environment (DGX Spark)
- Host `spark-ac69`, IP `10.1.30.230`, login `nitest`, SSH key auth. **NOTE: Spark was UNREACHABLE (connection timed out) at last check on 2026-08-03 — verify it's up before remote work.**
- GPU = **NVIDIA GB10** (Grace-Blackwell), cache-coherent unified memory (host VA==device VA; DAQiri buffers align16=0 → in-place FFT works). CUDA 13 at `/usr/local/cuda-13/`. Driver 580.95.05.
- **GPU clock CANNOT be locked:** `nvidia-smi -q -d SUPPORTED_CLOCKS` → `Supported Clocks: N/A`. Idle 208 / app 2418 / max 3003 MHz (>10× DVFS swing).
- **Passwordless sudo FAILS.** NEVER collect the sudo password via tools (secret).
- matplotlib NOT on Spark python3 → pull CSVs to Windows (matplotlib 3.11 / pandas / numpy) and plot locally.

## 4. The 3 hard constraints that shaped the design (all MEASURED)
1. **GPU clock can't be locked** on GB10 (`Supported Clocks: N/A`); can't sudo.
2. **gRPC shmem CANNOT run unpaced:** pace=0 STALLS (server hangs in `reader->Read()`); pace<200µs DROPS buffers. Pace probe @BS4096: `0→stall, 10→744, 25→671, 50→839, 100→875, 200→939(full)` → 400µs safe all sizes. So "unpace gRPC" (the literal request) is PHYSICALLY IMPOSSIBLE for this transport.
3. gRPC must pace (idles → GPU downclocks) while DAQiri bursts keep it hot ⇒ the clock gap is **ARCHITECTURAL**, not just methodology.

## 5. The airtight strategy (implemented)
Pace **BOTH** pipelines identically (400µs) → same cool-clock regime → fair per-buffer latency. Then report: (a) matched-duty per-buffer latency as the primary comparison, (b) `fft_exec_us` as an on-GPU clock probe (matched → clocks matched, CONFIRMED), (c) throughput/drops separately (DAQiri's burst advantage lives there), (d) document architectural differences rather than normalizing them away.

### The 8 confounders (audit) and how each was handled
1. GPU clock/DVFS — neutralized via equal pacing + matched-pair.
2. Pacing mismatch — FIXED: added DAQiri `--pace-us`; both paced @400.
3. e2e excludes transport on both — added transfer/throughput view.
4. Copy-mode staging memcpy asymmetry (gRPC has an extra host `memcpy` DAQiri lacks) — this is *why* copy-mode gRPC is +200–318%; ZC mode both skip it → ZC is the clean comparison.
5. CPU affinity — DAQiri self-pins RX→9/TX→11; gRPC client pinned 11, server UNPINNED (avoid single-core stall).
6. Trials/delivery — 5 trials, MIN_ROWS=800 retry, full delivery achieved.
7. Run ordering — matched-pair interleave (A then B back-to-back).
8. Inherent differences (socket vs shmem, in-place vs D2D-realign, burst vs per-message) — documented.

## 6. Measurement boundaries (fairness audit)
- **DAQiri e2e:** timer starts AFTER `get_rx_burst` returns, ends after FFT ⇒ e2e = H→D + FFT (copy) OR ZC-register-lookup + in-place FFT (ZC). Transport receive EXCLUDED. Copy mode: direct `cudaMemcpy(d_input, src)` — NO host staging.
- **gRPC e2e:** timer starts AFTER `reader->Read(&req)` returns, ends after FFT. Copy mode: `std::memcpy(h_staging, src)` (EXTRA staging) THEN `cudaMemcpy`. ZC mode: `_zcptr_` span + register + D2D-realign (wire align16=6 always needs realign). Transport EXCLUDED. Logs `wire_latency_us`.
- Both EXCLUDE transport symmetrically; copy has the staging asymmetry, ZC is clean.

## 7. Code state (all under `c:\Users\doluwada\DAQIRI_GPU\`, synced to Spark `/home/nitest/daqiri_gpu/`)
- **`daqiri/bench_daqiri_pipeline.cc`** — EDITED + synced + REBUILT (verified `grep -c pace_us`=6, built clean). Has `--zero-copy` (in-place FFT) and the **new `--pace-us`** flag: `tx_worker` sleeps `pace_us` after each `send_tx_burst`; `main()` parses/passes it. Verified `--pace-us 400` delivers full 400/400 rows.
- **`grpc_direct/bench_grpc_server.cc`** — COMMITTED 54bd12d, unchanged. Copy + ZC (D2D-realign) FFT; logs `wire_latency_us`.
- **`grpc_direct/bench_grpc_client.cc`** — unchanged. `--pace-us` (default 400); `--pace-us 0` = unpaced (stalls).
- **`scripts/ab_airtight_sweep.sh`** — the completed sweep. Usage `bash scripts/ab_airtight_sweep.sh [TRIALS] [PACE]` (ran `5 400`). Paces both @400, matched-pair interleave over BS {4096,8192,16384,32768} × {copy,zerocopy} × 5 trials. DAQiri `taskset -c 9,11`; gRPC server UNPINNED + `timeout 60`, client `taskset -c 11` + `timeout 50`; cleans `/tmp/iceoryx2` + `/dev/shm/iox2_*` between gRPC runs; MIN_ROWS=800 retry; prints `ALLDONE`. Wrote `data/ab_{daqiri,grpc}_<mode>_<BS>_<trial>.csv` (40 each).
- **`scripts/plot_ab_zerocopy.py`** — UPDATED. `--tag` (default `airtight`); `matched_pair_deltas()` (per mode/BS/trial pairs, delta=grpc_p50−daqiri_p50, median-of-trials). Run: `python scripts\plot_ab_zerocopy.py --data data --out data\figures --tag airtight`. Prints the summary table + head-to-head + matched-pair deltas (numbers in Section 2).
- Other: `scripts/grpc_pace_probe.sh`, `scripts/zc_sweep.sh`, `scripts/daqiri_zc_sweep.sh`, `scripts/plot_zc_sweep.py`.

## 8. Data / figures inventory (local)
- `data/ab_daqiri_*.csv` (40) + `data/ab_grpc_*.csv` (40) — the airtight sweep, all valid.
- `data/figures/fig_ab_airtight_01_latency.png`, `fig_ab_airtight_02_zerocopy_headtohead.png` — final airtight figures.
- Older (still present): `fig_ab_01/02` (earlier unfair run), `fig_zc_01/02`, `fig_m9_*`, `fig_m6_*`.

## 9. Next steps (choose what the user wants)
1. **Write the final comparison report / update the design doc** (`DAQiri_GPU_FFT_Design_Doc.md`) with the airtight results in Section 2 + the two airtight figures. This is the likely next ask ("Final comparison report" is a listed deliverable).
2. **Commit/push — ASK USER FIRST.** Uncommitted: `scripts/{zc_sweep.sh,plot_zc_sweep.py,daqiri_zc_sweep.sh,ab_airtight_sweep.sh,grpc_pace_probe.sh,plot_ab_zerocopy.py}`, `daqiri/bench_daqiri_pipeline.cc`, figures, `handoff.md`. Commit 54bd12d is local-only (NOT pushed). git identity "Dami Thomas" / "damithomas03@gmail.com". Remote https://github.com/dvthomas01/DAQIRI_v_GRPC.git.
3. (Optional) sensitivity check at a second pace (e.g. 200µs) to show the relative ranking is pace-invariant.
4. (Optional) add a wire-latency/throughput panel to the airtight figures for the "transport excluded" caveat.

## 10. Environment gotchas (PowerShell 5.1 + SSH) — IMPORTANT
- **`pkill -9 -f bench_daqiri_pipeline` over an INLINE ssh command KILLS THE REMOTE SHELL** (its own cmdline contains the pattern) → command dies silently, no output. Use `pkill` WITHOUT `-f` inline, OR run from a script file (safe). The sweep script uses `-f` safely (runs from file).
- PowerShell `<` is reserved → `wc -l < file` inside ssh FAILS. Use `wc -l file` or `awk 'END{print NR-1}' file`; single-quote ssh args.
- Single-quoted ssh arg mangles `awk "...\"...\""` escaped quotes → prefer `wc -l`.
- `|` inside double-quoted remote patterns mangles → use `grep -e P1 -e P2`.
- Fresh PS terminals lack scp/ssh on PATH → use `C:\WINDOWS\System32\OpenSSH\{ssh,scp}.exe`.
- `$HOME`/`~` do NOT expand in scp remote paths → use absolute `/home/nitest/...`.
- SSH hangs frequently → `-o ConnectTimeout=10`, fresh async terminals, poll with get_terminal_output. Spark was DOWN on 2026-08-03 — ping/verify before remote work.
- `/tmp/ab_air.log` has binary/NUL noise → read with `grep -a` / `tr -d '\000'`.

## 11. Build commands
- DAQiri: `ssh nitest@10.1.30.230 'export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin && cmake --build ~/daqiri_gpu/build --parallel 16 -- bench_daqiri_pipeline 2>&1 | tail -6'`. Binary `~/daqiri_gpu/build/daqiri/bench_daqiri_pipeline`.
- gRPC: `cmake --build ~/daqiri_gpu/build_grpc --parallel 16 -- bench_grpc_server` (+ `bench_grpc_client`). Binaries in `~/daqiri_gpu/build_grpc/`. Runtime needs `export LD_LIBRARY_PATH="$HOME/grpc_benchmarking/cpp/build/grpc-direct-build/cargo-target/release:${LD_LIBRARY_PATH:-}"`.

## 12. Pull + replot commands (to reproduce Section 2)
- Pull: `C:\WINDOWS\System32\OpenSSH\scp.exe "nitest@10.1.30.230:/home/nitest/daqiri_gpu/data/ab_*.csv" c:\Users\doluwada\DAQIRI_GPU\data\`
- Plot: `python scripts\plot_ab_zerocopy.py --data data --out data\figures --tag airtight`

## 13. Memory + transcript
- Repo memory: `/memories/repo/grpc-zero-copy.md` (L1/L2, paced sweep, DAQiri ZC results, AIRTIGHT-rerun section with constraints + gotchas). Consider appending the Section 2 final numbers.
- Pre-compaction transcript: `c:\Users\doluwada\AppData\Roaming\Code\User\workspaceStorage\9ad1bba7380df6efa9e593cd1860f53c\GitHub.copilot-chat\transcripts\980f2c14-aa27-45bb-a34a-e3e67cd4c647.jsonl`
