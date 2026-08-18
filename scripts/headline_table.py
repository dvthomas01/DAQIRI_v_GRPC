#!/usr/bin/env python3
"""Build the headline table from data/headline_runs.csv.

Reports, per size:
  - median e2e p50 across reps for each arm (the number people quote)
  - median residual (e2e_p50 - fft_p50) for each arm (the number that survives
    clock drift, because the transform time drifts with the clock and cancels)
  - speedup base->opt, and the remaining gap opt->daq

Then a paired sign test over every (size, rep) cell.  Reps are adjacent in time
within a size, and arms are adjacent within a rep, so a per-cell difference is
about as clock-fair as this box allows.  The sign test asks only "does the sign
of the difference hold up", which is the right question when the magnitudes are
noisy but the ordering is not.
"""
import csv
import sys
from collections import defaultdict
from math import comb

# Usage: headline_table.py [csv] [--arms A,B,C]
#   A = the pre-change / control arm
#   B = the arm under test
#   C = the reference we are chasing (DAQiri)
# Defaults to the headline sweep's arms.  Parameterised so the placement and
# registration probes can reuse this analyzer rather than forking a second copy
# that could drift out of agreement with it.
PATH = "data/headline_runs.csv"
A_CTL, A_TST, A_REF = "base", "opt", "daq"
_args = sys.argv[1:]
if "--arms" in _args:
    i = _args.index("--arms")
    A_CTL, A_TST, A_REF = _args[i + 1].split(",")
    del _args[i:i + 2]
if _args:
    PATH = _args[0]

rows = []
with open(PATH) as fh:
    for r in csv.DictReader(fh):
        if r["result"] != "OK":
            continue
        try:
            rows.append({
                "arm": r["arm"], "kb": int(r["kb"]), "rep": int(r["rep"]),
                "e2e": float(r["e2e_p50"]), "p99": float(r["e2e_p99"]),
                "fft": float(r["fft_p50"]), "resid": float(r["resid"]),
                "gitsha": r.get("gitsha", ""),
            })
        except ValueError:
            continue

if not rows:
    sys.exit(f"no usable rows in {PATH}")

shas = sorted({r.get("gitsha", "") for r in rows} - {""})
if len(shas) > 1:
    print(f"WARNING: rows span more than one build: {', '.join(shas)}")
    print("         arms may not be comparable.\n")


def med(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n:
        return float("nan")
    return xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])


cell = defaultdict(list)          # (arm, kb) -> [row, ...]
for r in rows:
    cell[(r["arm"], r["kb"])].append(r)

sizes = sorted({r["kb"] for r in rows})
reps = sorted({r["rep"] for r in rows})


def m(arm, kb, key):
    return med([x[key] for x in cell.get((arm, kb), [])])


print(f"headline: {len(rows)} runs, {len(sizes)} sizes, {len(reps)} reps, "
      f"arms interleaved within each rep\n")

hdr = ("KB", f"{A_CTL}_e2e", f"{A_TST}_e2e", f"{A_REF}_e2e", "speedup",
       "gap_us", "gap_%", f"{A_CTL}_res", f"{A_TST}_res", f"{A_REF}_res",
       f"{A_TST}_p99", f"{A_REF}_p99")
print(("{:<7}" + "{:>10}" * 11).format(*hdr))
print("-" * 117)

for kb in sizes:
    b, o, d = m(A_CTL, kb, "e2e"), m(A_TST, kb, "e2e"), m(A_REF, kb, "e2e")
    sp = b / o if o else float("nan")
    gap = o - d
    gpct = 100.0 * gap / d if d else float("nan")
    print(("{:<7}" + "{:>10.2f}" * 11).format(
        kb, b, o, d, sp, gap, gpct,
        m(A_CTL, kb, "resid"), m(A_TST, kb, "resid"), m(A_REF, kb, "resid"),
        m(A_TST, kb, "p99"), m(A_REF, kb, "p99")))

# ── where the remaining gap lives ────────────────────────────────────────────
# resid is defined as e2e - fft, so per run the identity is exact:
#     (opt_e2e - daq_e2e) = (opt_fft - daq_fft) + (opt_resid - daq_resid)
# Differencing WITHIN a (size, rep) cell before taking the median keeps that
# identity intact and cancels clock drift, which differencing the medians of
# each arm separately would not do.
#
# This split matters because the two terms have different owners. The resid
# term is ours: transport, threading, copy scheduling. The fft term is cuFFT
# doing the same transform on the same GPU in two different processes, so any
# difference there is not a transport problem at all and will not respond to
# transport work.
idx = {(r["arm"], r["kb"], r["rep"]): r for r in rows}
print(f"\nwhere the remaining {A_TST}->{A_REF} gap lives "
      f"(per-cell diffs, then median)")
print("-" * 117)
print(("{:<7}" + "{:>10}" * 5).format(
    "KB", "e2e_gap", "fft_gap", "res_gap", "fft_%", "res_%"))
for kb in sizes:
    e2e_d, fft_d, res_d = [], [], []
    for rep in reps:
        o, d = idx.get((A_TST, kb, rep)), idx.get((A_REF, kb, rep))
        if not o or not d:
            continue
        e2e_d.append(o["e2e"] - d["e2e"])
        fft_d.append(o["fft"] - d["fft"])
        res_d.append(o["resid"] - d["resid"])
    if not e2e_d:
        continue
    e, f, s = med(e2e_d), med(fft_d), med(res_d)
    fpct = 100.0 * f / e if e else float("nan")
    spct = 100.0 * s / e if e else float("nan")
    print(("{:<7}" + "{:>10.2f}" * 3 + "{:>9.0f}%" + "{:>9.0f}%").format(
        kb, e, f, s, fpct, spct))

# ── paired sign tests ────────────────────────────────────────────────────────
def sign_test(arm_a, arm_b, key):
    """Count cells where arm_a < arm_b, pairing on (kb, rep)."""
    idx = {(r["arm"], r["kb"], r["rep"]): r[key] for r in rows}
    wins = ties = total = 0
    for kb in sizes:
        for rep in reps:
            a = idx.get((arm_a, kb, rep))
            bb = idx.get((arm_b, kb, rep))
            if a is None or bb is None:
                continue
            total += 1
            if a < bb:
                wins += 1
            elif a == bb:
                ties += 1
    # two-sided exact binomial p under H0: p(win) = 0.5
    n = total - ties
    if n == 0:
        return wins, total, float("nan")
    k = min(wins, n - wins)
    tail = sum(comb(n, i) for i in range(0, k + 1)) / (2.0 ** n)
    return wins, total, min(1.0, 2.0 * tail)


print("\npaired sign tests (pairing on size x rep)")
print("-" * 117)
for a, b, key, label in (
    (A_TST, A_CTL, "resid", f"{A_TST} residual < {A_CTL} residual"),
    (A_TST, A_CTL, "e2e",   f"{A_TST} e2e      < {A_CTL} e2e"),
    (A_TST, A_CTL, "fft",   f"{A_TST} fft      < {A_CTL} fft"),
    (A_REF, A_TST, "resid", f"{A_REF} residual < {A_TST} residual"),
    (A_REF, A_TST, "e2e",   f"{A_REF} e2e      < {A_TST} e2e"),
    (A_REF, A_TST, "fft",   f"{A_REF} fft      < {A_TST} fft"),
):
    w, t, p = sign_test(a, b, key)
    print(f"  {label:36s}  {w}/{t} cells   p = {p:.4g}")

print("\nnote: e2e medians move with the GPU clock and are only comparable")
print("      within a rep; the residual columns are the drift-resistant ones.")
