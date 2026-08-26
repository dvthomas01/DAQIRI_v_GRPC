#!/usr/bin/env python3
"""
Summarize the four-arm 4 MiB sweep in data/deck_4arm_4mib.csv.

The sweep records e2e, fft and residual for four transport arms at one payload
size, twelve reps per pacing mode, with each arm rotated through all four
positions. This script turns that into the numbers slide 6 needs:

  1. Per-arm median with a distribution-free confidence interval, which is what
     the error bars on the slide are drawn from.
  2. Paired within-rep differences against DAQiri, with an exact sign test.
     A bare median of twelve numbers cannot tell you whether a few microseconds
     of separation is real; the paired comparison can, because both arms in a
     pair ran seconds apart on the same warm GPU.
  3. The position effect, which is the check that the rotation did its job. If
     position 1 is systematically slow, the rotation absorbed that bias rather
     than letting it land on whichever arm happened to go first.
  4. The SM clock range, so a reader can see the clock was not drifting under
     the comparison.

Both pacing modes are reported separately and never pooled. The two regimes do
not agree about the RDMA arm, and averaging them would hide that rather than
report it.

Usage:  python scripts/deck_4arm_table.py [csv_path]
"""

import csv
import sys
from collections import defaultdict

# The plain-language names. Script tags are an implementation detail and should
# not appear on a slide or in this output.
ARM_NAMES = {
    "base": "gRPC-Direct (before)",
    "opt": "gRPC-Direct (optimized)",
    "extbuf": "gRPC-Direct over RDMA",
    "daq": "DAQiri",
}
ARM_ORDER = ["base", "opt", "extbuf", "daq"]
BASELINE = "daq"

MODE_NAMES = {
    "sat": "saturated (25 us pacing, offered rate far above the link)",
    "unsat": "unsaturated (offered rate about 8x below the link)",
}


def median(xs):
    s = sorted(xs)
    n = len(s)
    if n == 0:
        return float("nan")
    mid = n // 2
    if n % 2:
        return s[mid]
    return 0.5 * (s[mid - 1] + s[mid])


def binom_cdf(k, n):
    """P(X <= k) for X ~ Binomial(n, 0.5)."""
    if k < 0:
        return 0.0
    if k >= n:
        return 1.0
    total = 0
    c = 1
    for i in range(0, k + 1):
        total += c
        c = c * (n - i) // (i + 1)
    return total / float(2 ** n)


def median_ci(xs, level=0.95):
    """
    Distribution-free confidence interval for the median, from order statistics.

    Picks the largest k whose interval [x_(k), x_(n+1-k)] still covers at least
    `level`. Returns (low, high, actual_coverage). This assumes nothing about
    the shape of the distribution, which matters here because the latency
    samples are medians of skewed per-message distributions.
    """
    s = sorted(xs)
    n = len(s)
    if n < 3:
        return (s[0], s[-1], 0.0) if s else (float("nan"), float("nan"), 0.0)
    best = None
    for k in range(1, n // 2 + 1):
        cov = 1.0 - 2.0 * binom_cdf(k - 1, n)
        if cov >= level:
            best = (s[k - 1], s[n - k], cov)
        else:
            break
    if best is None:
        return (s[0], s[-1], 1.0 - 2.0 * binom_cdf(0, n))
    return best


def sign_test(diffs):
    """
    Exact two-sided sign test on paired differences.

    Zeros are dropped rather than split, which is the conservative choice.
    Returns (n_positive, n_used, p).
    """
    nz = [d for d in diffs if d != 0.0]
    n = len(nz)
    pos = sum(1 for d in nz if d > 0)
    if n == 0:
        return (0, 0, 1.0)
    k = min(pos, n - pos)
    p = min(1.0, 2.0 * binom_cdf(k, n))
    return (pos, n, p)


def load(path):
    rows = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            try:
                rows.append(
                    {
                        "arm": r["arm"],
                        "mode": r["mode"],
                        "pace_us": float(r["pace_us"]),
                        "rep": int(r["rep"]),
                        "pos": int(r["pos"]),
                        "e2e": float(r["e2e_p50"]),
                        "fft": float(r["fft_p50"]),
                        "resid": float(r["resid"]),
                        "n": int(r["n"]),
                        "mhz": float(r["sm_mhz"]),
                    }
                )
            except (ValueError, KeyError):
                # A cell that failed to produce a number is dropped here and
                # reported as a missing rep in the counts below, rather than
                # silently becoming a zero.
                continue
    return rows


def report_mode(rows, mode):
    sub = [r for r in rows if r["mode"] == mode]
    if not sub:
        return
    pace = sub[0]["pace_us"]
    print()
    print("=" * 78)
    print("MODE: %s" % MODE_NAMES.get(mode, mode))
    print("pace %.0f us, %d cells" % (pace, len(sub)))
    print("=" * 78)

    by_arm = defaultdict(list)
    for r in sub:
        by_arm[r["arm"]].append(r)

    print()
    print("Per-arm medians. The interval is the error bar for the slide.")
    print()
    hdr = "%-26s %5s  %8s  %-18s  %8s  %8s"
    print(hdr % ("arm", "reps", "e2e p50", "95% CI of median", "fft p50", "resid"))
    print("-" * 84)
    for a in ARM_ORDER:
        rs = by_arm.get(a, [])
        if not rs:
            continue
        e = [r["e2e"] for r in rs]
        lo, hi, cov = median_ci(e)
        print(
            hdr
            % (
                ARM_NAMES[a],
                len(rs),
                "%.2f" % median(e),
                "%.2f .. %.2f" % (lo, hi),
                "%.2f" % median([r["fft"] for r in rs]),
                "%.2f" % median([r["resid"] for r in rs]),
            )
        )
    any_arm = next((by_arm[a] for a in ARM_ORDER if by_arm.get(a)), [])
    cov = median_ci([r["e2e"] for r in any_arm])[2] if any_arm else 0.0
    print()
    print("(CI is from order statistics, coverage %.1f%% at this rep count.)"
          % (100.0 * cov))

    # Paired differences. Positive means the arm is slower than DAQiri.
    base_by_rep = {r["rep"]: r for r in by_arm.get(BASELINE, [])}
    if base_by_rep:
        print()
        print("Paired against %s, within the same rep. Positive means slower."
              % ARM_NAMES[BASELINE])
        print()
        ph = "%-26s %-8s %9s  %-18s %8s %8s"
        print(ph % ("arm", "metric", "median d", "95% CI of d", "slower", "p"))
        print("-" * 84)
        for a in ARM_ORDER:
            if a == BASELINE:
                continue
            rs = by_arm.get(a, [])
            if not rs:
                continue
            for metric in ("e2e", "fft", "resid"):
                diffs = []
                for r in rs:
                    b = base_by_rep.get(r["rep"])
                    if b is not None:
                        diffs.append(r[metric] - b[metric])
                if not diffs:
                    continue
                lo, hi, _ = median_ci(diffs)
                pos, used, p = sign_test(diffs)
                print(
                    ph
                    % (
                        ARM_NAMES[a] if metric == "e2e" else "",
                        metric,
                        "%.2f" % median(diffs),
                        "%.2f .. %.2f" % (lo, hi),
                        "%d/%d" % (pos, used),
                        "%.3f" % p,
                    )
                )
            print()

    # Position effect. This is the rotation's receipt.
    by_pos = defaultdict(list)
    for r in sub:
        by_pos[r["pos"]].append(r["e2e"])
    print("Position effect on e2e, pooled over arms. The rotation exists so")
    print("that any slot bias is shared equally rather than charged to one arm.")
    print()
    for p in sorted(by_pos):
        v = by_pos[p]
        print("  position %d:  median %8.2f   n=%d" % (p, median(v), len(v)))

    mhz = [r["mhz"] for r in sub]
    print()
    print("SM clock across these cells: %.0f .. %.0f MHz, median %.0f"
          % (min(mhz), max(mhz), median(mhz)))

    msgs = sorted({r["n"] for r in sub})
    print("Message counts seen: %s" % ", ".join(str(m) for m in msgs))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/deck_4arm_4mib.csv"
    rows = load(path)
    if not rows:
        print("no usable rows in %s" % path)
        return 1

    print("source: %s" % path)
    print("payload: 4 MiB (1048576 float32 samples)")
    print("rows: %d" % len(rows))

    for mode in ("sat", "unsat"):
        report_mode(rows, mode)

    # The cross-mode question, stated rather than buried.
    print()
    print("=" * 78)
    print("HOW MUCH THE PACING REGIME MOVES EACH ARM")
    print("=" * 78)
    print()
    print("If an arm's number depends on the offered rate, then any single")
    print("pacing choice picks a winner. That is a property of the arm and")
    print("belongs on the slide, not in a footnote.")
    print()
    print("%-26s %10s %10s %10s" % ("arm", "sat e2e", "unsat e2e", "shift"))
    print("-" * 60)
    for a in ARM_ORDER:
        s = [r["e2e"] for r in rows if r["arm"] == a and r["mode"] == "sat"]
        u = [r["e2e"] for r in rows if r["arm"] == a and r["mode"] == "unsat"]
        if not s or not u:
            continue
        ms, mu = median(s), median(u)
        print("%-26s %10.2f %10.2f %+10.2f" % (ARM_NAMES[a], ms, mu, mu - ms))
    return 0


if __name__ == "__main__":
    sys.exit(main())
