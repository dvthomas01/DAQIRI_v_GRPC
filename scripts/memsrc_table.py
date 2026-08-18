#!/usr/bin/env python3
"""Summarise the cuFFT input-placement ladder (data/memsrc_runs.csv).

The question this answers: does the memory a transform reads FROM change how
long the transform takes?  The pipeline comparison said yes and said the effect
grows with payload.  This harness removes gRPC, DAQiri, the network and the
Rust runtime, holds alignment and the plan constant, and varies only the memory
kind, so whatever shows up here is the memory kind and nothing else.

Reported two ways on purpose:
  * absolute microseconds, which is what anyone will ask for first
  * microseconds per megabyte, which is the shape that matters.  A cost that is
    really about the memory should stay roughly flat per megabyte; a fixed
    per-call overhead shrinks per megabyte as payloads grow.

Pairing is within (size, rep) before any median is taken, so GPU clock drift
between reps cancels instead of leaking into the comparison.
"""
import csv
import sys
from collections import defaultdict
from math import comb

PATH = sys.argv[1] if len(sys.argv) > 1 else "data/memsrc_runs.csv"

rows = []
with open(PATH, newline="") as f:
    for r in csv.DictReader(f):
        if r.get("fft_p50") in (None, "", "NA"):
            continue
        rows.append(r)

arms, sizes, notes = [], [], {}
cell = {}          # (arm, kb, rep) -> p50
wcell = {}         # (arm, kb, rep) -> producer write p50
tcell = {}         # (arm, kb, rep) -> write + transform
for r in rows:
    kb = int(r["kb"]); rep = int(r["rep"]); a = r["arm"]
    cell[(a, kb, rep)] = float(r["fft_p50"])
    if r.get("write_p50") not in (None, "", "NA"):
        wcell[(a, kb, rep)] = float(r["write_p50"])
        tcell[(a, kb, rep)] = float(r["total_p50"])
    if a not in arms:  arms.append(a)
    if kb not in sizes: sizes.append(kb)
    if r.get("note", "-") not in ("-", ""):
        notes[a] = r["note"]
sizes.sort()
reps = sorted({int(r["rep"]) for r in rows})

print(f"placement ladder: {len(rows)} rows, {len(sizes)} sizes, "
      f"{len(reps)} reps, {len(arms)} arms interleaved per iteration")
for a, n in notes.items():
    print(f"  note: arm '{a}' was actually built as: {n}")
print()


def med(v):
    v = sorted(v)
    n = len(v)
    return v[n // 2] if n % 2 else 0.5 * (v[n // 2 - 1] + v[n // 2])


def show(title, scale, src=None):
    src = cell if src is None else src
    print(title)
    print("-" * 78)
    print(f"{'KB':>7} " + "".join(f"{a:>12}" for a in arms))
    for kb in sizes:
        mb = kb / 1024.0
        line = f"{kb:>7} "
        for a in arms:
            vals = [src[(a, kb, r)] for r in reps if (a, kb, r) in src]
            if not vals:
                line += f"{'--':>12}"
            else:
                v = med(vals)
                line += f"{(v / mb if scale else v):>12.2f}"
        print(line)
    print()


show("cuFFT GPU time, median over reps (microseconds)", False)
if wcell:
    show("producer WRITE time into each memory kind (microseconds)", False, wcell)
    show("TOTAL: write + transform (microseconds)  <- the honest metric", False, tcell)
    print("The transform column alone is not a verdict.  In the pipeline the")
    print("producer's write sits outside the measured window, so an arm that")
    print("writes slowly and transforms quickly would look free when it is not.")
    print()
else:
    show("same thing per megabyte (microseconds per MB)", True)


def sign_p(k, n):
    if n == 0:
        return 1.0
    tail = sum(comb(n, i) for i in range(k, n + 1)) / (2.0 ** n)
    return min(1.0, 2.0 * tail)


print("paired sign tests (pairing on size x rep, so clock drift cancels)")
print("-" * 78)
base = arms[0]
for a in arms[1:]:
    wins = tot = 0
    for kb in sizes:
        for r in reps:
            if (a, kb, r) in cell and (base, kb, r) in cell:
                tot += 1
                if cell[(a, kb, r)] < cell[(base, kb, r)]:
                    wins += 1
    print(f"  {a:>10} faster than {base:<10} {wins:>3}/{tot} cells   p = {sign_p(wins, tot):.4g}")

print()
print("head-to-head on the question that started this: registered shared memory")
print("(what our pipeline gets) vs pinned host memory (what DAQiri's uses)")
print("-" * 78)
if "shmreg" in arms and "hostalloc" in arms:
    wins = tot = 0
    for kb in sizes:
        d = []
        for r in reps:
            if ("shmreg", kb, r) in cell and ("hostalloc", kb, r) in cell:
                diff = cell[("shmreg", kb, r)] - cell[("hostalloc", kb, r)]
                d.append(diff)
                tot += 1
                if diff > 0:
                    wins += 1
        if d:
            print(f"  {kb:>7} KB   shmreg - hostalloc = {med(d):+7.2f} us")
    print(f"\n  shmreg SLOWER than hostalloc in {wins}/{tot} cells   p = {sign_p(wins, tot):.4g}")
