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
import sys

# Pattern is an argument so this can be pointed at any run's CSVs, not just the
# drop probe's.  Defaults to the drop probe for backward compatibility.
pattern = sys.argv[1] if len(sys.argv) > 1 else "data/drop_*.csv"

hdr = "%-30s %5s %7s %7s %5s %9s %9s %9s"
print("pattern: %s" % pattern)
print(hdr % ("file", "rows", "minseq", "maxseq", "gaps", "p50", "p99", "max"))
print("-" * 90)

clean = holed = skipped = 0
for f in sorted(glob.glob(pattern)):
    seqs, lat = [], []
    with open(f) as fh:
        rdr = csv.DictReader(fh)
        if "seq_num" not in (rdr.fieldnames or []):
            skipped += 1
            continue
        for r in rdr:
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
        holed += 1
        print("      holes: " + ", ".join("%d->%d" % g for g in gaps[:12]))
    else:
        clean += 1

print("-" * 90)
print("files with a CONTIGUOUS measured window: %d" % clean)
print("files containing holes:                  %d" % holed)
print("files skipped (no seq_num column):       %d" % skipped)
print()
print("A contiguous window means every published percentile was computed over")
print("an unbroken run of messages, so the shortfall in n is a truncated tail")
print("rather than losses scattered through the measured region.")
