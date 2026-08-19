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
    # Two-sided sign test.  This used to sum only the upper tail, from k to n,
    # which is right when the arm wins everything and silently wrong when it
    # loses everything: 0 wins out of 45 came out as p = 1, reading as "no
    # effect" for what is in fact the strongest effect on the page.  Taking the
    # smaller tail makes it symmetric, so consistently slower is as detectable
    # as consistently faster.
    if n == 0:
        return 1.0
    m = min(k, n - k)
    tail = sum(comb(n, i) for i in range(0, m + 1)) / (2.0 ** n)
    return min(1.0, 2.0 * tail)


# The sign tests below run on TOTAL, not on the transform alone.  The tables
# above already say total is the honest metric, and testing a different column
# from the one declared honest is how a verdict drifts away from its evidence.
#
# They are also printed per size before being pooled.  Pooling is only valid
# where the effect exists at every size, and the transform penalty does not:
# it is absent below about 2 MB and large above it.  Pooled on its own, a real
# 15 us effect at 4 MB comes out at p = 1, because it is being averaged against
# eight sizes where there is nothing to find.
def sign_table(title, src, base):
    print(title)
    print("-" * 78)
    print(f"{'arm':>12} " + "".join(f"{kb:>6}" for kb in sizes) + f"{'pooled':>10}{'p':>10}")
    for a in arms:
        if a == base:
            continue
        line = f"{a:>12} "
        pw = pt = 0
        for kb in sizes:
            w = t = 0
            for r in reps:
                if (a, kb, r) in src and (base, kb, r) in src:
                    t += 1
                    if src[(a, kb, r)] < src[(base, kb, r)]:
                        w += 1
            pw += w; pt += t
            line += f"{w:>4}/{t}"
        line += f"{pw:>7}/{pt}{sign_p(pw, pt):>10.4g}"
        print(line)
    print(f"  cells are 'faster than {base}', per size, out of {len(reps)} reps")
    print()


if tcell:
    sign_table("paired sign tests on TOTAL (write + transform), vs " + arms[0],
               tcell, arms[0])
    sign_table("same tests on the TRANSFORM column alone, vs " + arms[0],
               cell, arms[0])

print("head-to-head on the question that started this: registered shared memory")
print("(what our pipeline gets) vs pinned host memory (what DAQiri's uses)")
print("-" * 78)
if "shmreg" in arms and "hostalloc" in arms:
    print(f"{'KB':>7}{'fft delta':>12}{'write delta':>14}{'total delta':>14}"
          f"{'fft sign':>10}")
    for kb in sizes:
        f_d, w_d, t_d, w_wins, n = [], [], [], 0, 0
        for r in reps:
            if ("shmreg", kb, r) in cell and ("hostalloc", kb, r) in cell:
                d = cell[("shmreg", kb, r)] - cell[("hostalloc", kb, r)]
                f_d.append(d); n += 1
                if d > 0:
                    w_wins += 1
            if ("shmreg", kb, r) in tcell and ("hostalloc", kb, r) in tcell:
                w_d.append(wcell[("shmreg", kb, r)] - wcell[("hostalloc", kb, r)])
                t_d.append(tcell[("shmreg", kb, r)] - tcell[("hostalloc", kb, r)])
        if f_d:
            print(f"{kb:>7}{med(f_d):>+12.2f}{med(w_d):>+14.2f}{med(t_d):>+14.2f}"
                  f"{w_wins:>7}/{n}")
    print("  positive = shmreg is slower, which is the direction that costs us")
    print()

# ── Phase 1 verdict: does any flag close the gap? ───────────────────────────
# The whole point of the flag ladder.  If a cudaHostRegister flag recovers most
# of the allocate-vs-register penalty, the fix is one line and the RDMA
# transport becomes optional; if none does, the penalty is inherent to
# registration and owning the allocation is the only way out.  Reported as the
# fraction of the gap closed so the answer does not depend on reading two
# tables side by side.
if "shmreg" in arms and "hostalloc" in arms:
    print("Phase 1 verdict: fraction of the shmreg-to-hostalloc gap that each")
    print("flag variant closes, on TOTAL (positive = closes it, 100% = fixed)")
    print("-" * 78)
    others = [a for a in arms if a not in ("shmreg", "hostalloc")]
    print(f"{'KB':>7}{'gap us':>9} " + "".join(f"{a:>12}" for a in others))
    for kb in sizes:
        sh = [tcell[("shmreg", kb, r)] for r in reps if ("shmreg", kb, r) in tcell]
        ha = [tcell[("hostalloc", kb, r)] for r in reps if ("hostalloc", kb, r) in tcell]
        if not sh or not ha:
            continue
        gap = med(sh) - med(ha)
        line = f"{kb:>7}{gap:>9.2f} "
        for a in others:
            v = [tcell[(a, kb, r)] for r in reps if (a, kb, r) in tcell]
            if not v or abs(gap) < 1e-9:
                line += f"{'--':>12}"
            else:
                line += f"{100.0 * (med(sh) - med(v)) / gap:>11.0f}%"
        print(line)
    print("  an allocation-side arm should read near 100% (it IS the fast side);")
    print("  a registration-side arm reading near 0% means its flag changed nothing")

