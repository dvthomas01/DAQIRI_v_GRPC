#!/usr/bin/env python3
"""Two follow-up checks on data/headline_runs.csv.

CHECK 1 -- delivery accounting.  The gRPC arms report n of 184..200 while
DAQiri reports 250.  Question: is the gRPC shortfall size-dependent?  A
shortfall that concentrates at small buffers is the known benign transient
(session closes while the tail is still in flight).  A shortfall that grows
with size would mean we are dropping payload under load, which would bias the
latency percentiles and would have to be fixed before publishing anything.

CHECK 2 -- cuFFT time by INPUT MEMORY SOURCE.  This is the interesting one.
The three arms feed the transform from three different places:

    base : --no-zc-align forces a realign copy, so cuFFT reads d_input,
           which is cudaMalloc'd DEVICE memory.
    opt  : in-place on the loaned iceoryx2 shmem buffer, mapped to the device
           via cudaHostRegister + cudaHostGetDevicePointer, so cuFFT reads
           MAPPED HOST memory.
    daq  : in-place on DAQiri's RDMA host_pinned MR, also mapped host memory
           but from a different allocator with stronger page alignment.

Same plan, same size, same batch, same out-of-place config, same GPU (verified
by code read).  So if fft_p50 differs across arms, the input memory source is
the only remaining candidate.

A previous session reported a "memory-source ladder" and then RETRACTED it as
a cross-run thermal artifact.  That retraction was correct for the data it was
based on.  This check is different: base/opt/daq are measured ADJACENTLY inside
each (size, rep) cell, so differencing within the cell cancels drift.  If the
ladder survives that, it was real all along.

CONFOUND, stated up front: base differs from opt in TWO ways, --no-zc-align AND
--no-opt-stream, so the base-vs-opt FFT delta mixes input placement with the
stream/spin change.  The opt-vs-daq delta is the clean one for placement.
Disentangling base requires a dedicated arm.
"""
import csv
import sys
from collections import defaultdict
from math import comb

PATH = sys.argv[1] if len(sys.argv) > 1 else "data/headline_runs.csv"

rows = []
with open(PATH) as fh:
    for r in csv.DictReader(fh):
        if r["result"] != "OK":
            continue
        rows.append({
            "arm": r["arm"], "kb": int(r["kb"]), "rep": int(r["rep"]),
            "e2e": float(r["e2e_p50"]), "fft": float(r["fft_p50"]),
            "resid": float(r["resid"]), "n": int(r["n"]),
        })

sizes = sorted({r["kb"] for r in rows})
reps = sorted({r["rep"] for r in rows})
idx = {(r["arm"], r["kb"], r["rep"]): r for r in rows}


def med(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n:
        return float("nan")
    return xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])


def sign_p(wins, total):
    """Two-sided exact binomial p under H0: p(win) = 0.5."""
    if total == 0:
        return float("nan")
    k = min(wins, total - wins)
    tail = sum(comb(total, i) for i in range(0, k + 1)) / (2.0 ** total)
    return min(1.0, 2.0 * tail)


# ── CHECK 1: is the delivery shortfall size-dependent? ───────────────────────
print("CHECK 1: delivery accounting, n received per arm")
print("-" * 72)
print("{:<8}{:>10}{:>10}{:>10}".format("KB", "base_n", "opt_n", "daq_n"))
for kb in sizes:
    print("{:<8}{:>10}{:>10}{:>10}".format(
        kb,
        med([r["n"] for r in rows if r["arm"] == "base" and r["kb"] == kb]),
        med([r["n"] for r in rows if r["arm"] == "opt" and r["kb"] == kb]),
        med([r["n"] for r in rows if r["arm"] == "daq" and r["kb"] == kb]),
    ))

small = [r["n"] for r in rows if r["arm"] in ("base", "opt") and r["kb"] <= 128]
large = [r["n"] for r in rows if r["arm"] in ("base", "opt") and r["kb"] >= 1024]
print()
print(f"  gRPC arms, buffers <= 128 KB : median n = {med(small):.0f}")
print(f"  gRPC arms, buffers >= 1024 KB: median n = {med(large):.0f}")
print("  Shortfall concentrated at SMALL sizes => benign end-of-session")
print("  transient. Growing with size => real drops under load, must fix.")

# ── CHECK 2: cuFFT time by input memory source ───────────────────────────────
print()
print("CHECK 2: cuFFT p50 by input memory source (paired within each cell)")
print("-" * 72)
print("{:<8}{:>10}{:>10}{:>10}{:>12}{:>12}".format(
    "KB", "base_fft", "opt_fft", "daq_fft", "opt-daq", "opt-base"))

od_wins = ob_wins = total = 0
for kb in sizes:
    b = med([idx[("base", kb, r)]["fft"] for r in reps if ("base", kb, r) in idx])
    o = med([idx[("opt", kb, r)]["fft"] for r in reps if ("opt", kb, r) in idx])
    d = med([idx[("daq", kb, r)]["fft"] for r in reps if ("daq", kb, r) in idx])
    # per-cell paired diffs, which is what cancels clock drift
    od = med([idx[("opt", kb, r)]["fft"] - idx[("daq", kb, r)]["fft"]
              for r in reps if ("opt", kb, r) in idx and ("daq", kb, r) in idx])
    ob = med([idx[("opt", kb, r)]["fft"] - idx[("base", kb, r)]["fft"]
              for r in reps if ("opt", kb, r) in idx and ("base", kb, r) in idx])
    print("{:<8}{:>10.2f}{:>10.2f}{:>10.2f}{:>12.2f}{:>12.2f}".format(
        kb, b, o, d, od, ob))
    for r in reps:
        if ("opt", kb, r) in idx and ("daq", kb, r) in idx:
            total += 1
            if idx[("opt", kb, r)]["fft"] > idx[("daq", kb, r)]["fft"]:
                od_wins += 1
            if idx[("opt", kb, r)]["fft"] > idx[("base", kb, r)]["fft"]:
                ob_wins += 1

print()
print(f"  opt fft SLOWER than daq  fft in {od_wins}/{total} cells, "
      f"p = {sign_p(od_wins, total):.4g}")
print(f"  opt fft SLOWER than base fft in {ob_wins}/{total} cells, "
      f"p = {sign_p(ob_wins, total):.4g}")
print()
print("  Reminder: opt-vs-daq is the clean placement comparison.")
print("  opt-vs-base is CONFOUNDED (zc-align and opt-stream both differ).")
