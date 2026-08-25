#!/usr/bin/env python3
"""Read the variant exports already on disk. No benchmarks are re-run."""
import sqlite3, glob, os
from collections import Counter

for p in sorted(glob.glob("/tmp/proftest/v*.sqlite")):
    tag = os.path.basename(p)[:-7]
    cx = sqlite3.connect(p)
    T = {r[0] for r in cx.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    S = {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}
    cols = {c[1] for c in cx.execute("PRAGMA table_info(CUPTI_ACTIVITY_KIND_RUNTIME)")}
    c = Counter()
    tids = set()
    for nid, tid in cx.execute(
            "SELECT nameId, globalTid FROM CUPTI_ACTIVITY_KIND_RUNTIME"):
        c[S.get(nid, "?")] += 1
        tids.add(tid)
    k = 0
    if 'CUPTI_ACTIVITY_KIND_KERNEL' in T:
        k = list(cx.execute("SELECT count(*) FROM CUPTI_ACTIVITY_KIND_KERNEL"))[0][0]
    # globalTid packs the pid in its upper bits on Linux
    pids = {(t >> 24) for t in tids}
    print("%-9s launches=%-5d kernels=%-5d api=%-5d threads=%-3d pids=%-2d kerneltbl=%s"
          % (tag, c.get('cuLaunchKernel', 0), k, sum(c.values()),
             len(tids), len(pids), 'CUPTI_ACTIVITY_KIND_KERNEL' in T))
    for nm, n in c.most_common(5):
        print("        %-38s %5d" % (nm, n))
