#!/usr/bin/env python3
"""Read data/extbuf_stream_ab.csv and say whether --own-stream did anything.

The comparison is paired. Both variants run inside the same rep, minutes apart,
with the order swapped every rep, so clock drift and thermal drift land on both
equally. What matters is the within-rep difference, not the difference of two
medians taken over the whole file.

The effect being looked for is small. On the shared-memory arm the same
optimization moved the residual by 0.15 to 0.39 us, and a single cell here has
roughly 4.4 us of spread, so an unpaired comparison could not see it at any
sample size that finishes in an afternoon.

Reported per size:
  median paired difference, off minus on, so POSITIVE means --own-stream helped
  how many of the reps that difference was positive
  a two-sided exact sign test on that count
"""
import csv
import math
import sys
from collections import defaultdict

COLS = ("e2e_p50", "fft_p50", "residual")


def median(v):
    s = sorted(v)
    n = len(s)
    if not n:
        return None
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def sign_p(pos, neg):
    """Two-sided exact binomial on the non-tied pairs."""
    n = pos + neg
    if n == 0:
        return 1.0
    k = min(pos, neg)
    tail = sum(math.comb(n, i) for i in range(0, k + 1))
    return min(1.0, 2.0 * tail / (2 ** n))


def load(path):
    rows = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            try:
                rec = {
                    "variant": r["variant"],
                    "size": int(r["size"]),
                    "rep": int(r["rep"]),
                    "pos": int(r["pos"]),
                    "n": int(r["n"]),
                    "mhz": float(r["sm_mhz"]) if r["sm_mhz"] != "NA" else None,
                }
                for c in COLS:
                    rec[c] = float(r[c]) if r[c] != "NA" else None
                rows.append(rec)
            except (ValueError, KeyError):
                continue
    return rows


def kib(size):
    b = size * 4
    return f"{b // 1024} KiB" if b < 1024 ** 2 else f"{b // 1024 ** 2} MiB"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/extbuf_stream_ab.csv"
    rows = load(path)
    if not rows:
        print(f"no usable rows in {path}")
        return

    sizes = sorted({r["size"] for r in rows})
    print("=" * 78)
    print("external-buffer receiver, --own-stream on vs off")
    print(f"({path}, paired within rep, order swapped every rep)")
    print("=" * 78)

    for size in sizes:
        sub = [r for r in rows if r["size"] == size]
        reps = sorted({r["rep"] for r in sub})
        print(f"\n--- {kib(size)} payload ({size} samples) ---")
        print(f"{'':10}{'e2e us':>10}{'fft us':>10}{'residual us':>14}{'reps':>7}")
        for variant in ("off", "on"):
            v = [r for r in sub if r["variant"] == variant]
            vals = [median([x[c] for x in v if x[c] is not None]) for c in COLS]
            shown = ["  NA" if x is None else f"{x:.2f}" for x in vals]
            label = "off" if variant == "off" else "on (stream)"
            print(f"{label:10}{shown[0]:>10}{shown[1]:>10}{shown[2]:>14}{len(v):>7}")

        short = [r for r in sub if r["n"] < 0.98 * max(x["n"] for x in sub)]
        if short:
            worst = min(r["n"] for r in short)
            print(f"    NOTE: one or more cells recorded only {worst} messages.")

        print(f"\n    {'metric':<12}{'median off-on':>15}{'helped':>9}{'p':>8}"
              f"   (positive means --own-stream is faster)")
        for c in COLS:
            diffs = []
            for rep in reps:
                on = next((r[c] for r in sub
                           if r["rep"] == rep and r["variant"] == "on"), None)
                off = next((r[c] for r in sub
                            if r["rep"] == rep and r["variant"] == "off"), None)
                if on is not None and off is not None:
                    diffs.append(off - on)
            if not diffs:
                continue
            pos = sum(1 for d in diffs if d > 0)
            neg = sum(1 for d in diffs if d < 0)
            m = median(diffs)
            print(f"    {c:<12}{m:>15.3f}{f'{pos}/{len(diffs)}':>9}"
                  f"{sign_p(pos, neg):>8.3f}")

    mhz = [r["mhz"] for r in rows if r["mhz"]]
    if mhz:
        print(f"\n  SM clock across all cells: {min(mhz):.0f} .. {max(mhz):.0f} MHz"
              f"  (median {median(mhz):.0f})")

    print("\n  Reading this: expect residual AND fft to both move; use e2e as the")
    print("  headline.  fft is device-side ev_start..ev_stop, but ev_start is")
    print("  enqueued before the cuFFT launch, so host submission latency falls")
    print("  inside that window.  The spin keeps the submitting thread hot, which")
    print("  shortens it.  The saving splitting across two columns is an artefact")
    print("  of where the start event sits, not two separate effects.")


if __name__ == "__main__":
    main()
