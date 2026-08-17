#!/usr/bin/env python3
"""Are the drops inside the measured window, or only in warmup?

The server logs a row only for post-warmup buffers, and warmup counts *received*
messages, not sequence numbers.  So if a burst of losses happens early, the
measured window simply starts at a higher seq -- it does not necessarily contain
any holes.  This checks that directly: contiguous seq numbers in the CSV means
every published percentile was computed over an unbroken run of messages, and
the survivor-bias concern does not apply.
"""
import csv
import glob
import os

hdr = "%-30s %5s %7s %7s %5s %9s %9s %9s"
print(hdr % ("file", "rows", "minseq", "maxseq", "gaps", "p50", "p99", "max"))
print("-" * 90)

for f in sorted(glob.glob("data/drop_*.csv")):
    seqs, lat = [], []
    with open(f) as fh:
        for r in csv.DictReader(fh):
            seqs.append(int(r["seq_num"]))
            lat.append(float(r["e2e_latency_us"]))
    if not seqs:
        continue
    gaps = [(a, b) for a, b in zip(seqs, seqs[1:]) if b != a + 1]
    s = sorted(lat)

    def p(q):
        return s[min(len(s) - 1, int(q * len(s)))]

    print(hdr % (os.path.basename(f), len(seqs), min(seqs), max(seqs),
                 len(gaps), "%.2f" % p(.50), "%.2f" % p(.99), "%.2f" % s[-1]))
    if gaps:
        print("      holes: " + ", ".join("%d->%d" % g for g in gaps[:12]))
