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

PATH = sys.argv[1] if len(sys.argv) > 1 else "data/headline_runs.csv"

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

hdr = ("KB", "base_e2e", "opt_e2e", "daq_e2e", "speedup", "gap_us", "gap_%",
       "base_res", "opt_res", "daq_res", "opt_p99", "daq_p99")
print(("{:<7}" + "{:>10}" * 11).format(*hdr))
print("-" * 117)

for kb in sizes:
    b, o, d = m("base", kb, "e2e"), m("opt", kb, "e2e"), m("daq", kb, "e2e")
    sp = b / o if o else float("nan")
    gap = o - d
    gpct = 100.0 * gap / d if d else float("nan")
    print(("{:<7}" + "{:>10.2f}" * 11).format(
        kb, b, o, d, sp, gap, gpct,
        m("base", kb, "resid"), m("opt", kb, "resid"), m("daq", kb, "resid"),
        m("opt", kb, "p99"), m("daq", kb, "p99")))

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
    ("opt", "base", "resid", "opt residual < base residual"),
    ("opt", "base", "e2e",   "opt e2e      < base e2e"),
    ("daq", "opt",  "resid", "daq residual < opt  residual"),
    ("daq", "opt",  "e2e",   "daq e2e      < opt  e2e"),
):
    w, t, p = sign_test(a, b, key)
    print(f"  {label:32s}  {w}/{t} cells   p = {p:.4g}")

print("\nnote: e2e medians move with the GPU clock and are only comparable")
print("      within a rep; the residual columns are the drift-resistant ones.")
