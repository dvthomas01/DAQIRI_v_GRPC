#!/usr/bin/env python3
"""Answer one question from an nsys sqlite export: is the GPU busier, or idler.

Prints whether the GPU-side kernel table survived the export, and if it did,
the per-message kernel busy time broken out by kernel name. Pair that against
the CUDA-event transform time the benchmark itself reports, which is in the
run's own CSV: busy well below the event time means dead time between kernels,
busy close to it means the GPU is genuinely working that long.

Usage: nsys_kernel_probe.py <export.sqlite> [run.csv]
"""
import sqlite3
import sys


def tables(cur):
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    return {r[0] for r in cur.fetchall()}


def median(v):
    s = sorted(v)
    if not s:
        return float('nan')
    n = len(s)
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def main():
    db = sys.argv[1]
    runcsv = sys.argv[2] if len(sys.argv) > 2 else None
    con = sqlite3.connect(db)
    cur = con.cursor()
    t = tables(cur)

    # API side, to prove the session recorded anything at all.
    launches = 0
    if 'CUPTI_ACTIVITY_KIND_RUNTIME' in t and 'StringIds' in t:
        cur.execute("""SELECT COUNT(*) FROM CUPTI_ACTIVITY_KIND_RUNTIME r
                       JOIN StringIds s ON s.id = r.nameId
                       WHERE s.value LIKE '%LaunchKernel%'""")
        launches = cur.fetchone()[0]
    if 'CUPTI_ACTIVITY_KIND_DRIVER' in t and launches == 0 and 'StringIds' in t:
        cur.execute("""SELECT COUNT(*) FROM CUPTI_ACTIVITY_KIND_DRIVER d
                       JOIN StringIds s ON s.id = d.nameId
                       WHERE s.value LIKE '%LaunchKernel%'""")
        launches = cur.fetchone()[0]

    ktab = 'CUPTI_ACTIVITY_KIND_KERNEL'
    if ktab not in t:
        print('  kernel table : ABSENT   (api launches recorded: %d)' % launches)
        print('  GPU-side records did not survive. Nothing to say about busy time.')
        return

    cur.execute("SELECT COUNT(*) FROM " + ktab)
    nk = cur.fetchone()[0]
    if nk == 0:
        print('  kernel table : present but EMPTY   (api launches: %d)' % launches)
        return

    cur.execute("""SELECT s.value, k.start, k.end
                   FROM CUPTI_ACTIVITY_KIND_KERNEL k
                   JOIN StringIds s ON s.id = k.demangledName
                   ORDER BY k.start""")
    rows = cur.fetchall()

    # Steady state only: drop the first quarter and the last tenth, the same
    # treatment the stage analyzer uses, so warmup and teardown do not count.
    lo, hi = int(0.25 * len(rows)), int(0.90 * len(rows))
    rows = rows[lo:hi]
    if not rows:
        print('  too few kernel records after trimming')
        return

    # A message is one pass through the kernel sequence. Count messages by the
    # number of times the most frequent kernel name appears.
    counts = {}
    for name, s, e in rows:
        counts[name] = counts.get(name, 0) + 1
    top = max(counts.values())

    span_us = (rows[-1][2] - rows[0][1]) / 1000.0
    busy_ns = sum(e - s for _, s, e in rows)

    print('  kernel table : present, %d records (api launches: %d)' % (nk, launches))
    print('  messages in steady state (by most frequent kernel): %d' % top)
    print('  GPU busy per message : %8.2f us' % (busy_ns / 1000.0 / top))
    print('  wall span per message: %8.2f us' % (span_us / top))
    print('  by kernel:')
    for name in sorted(counts, key=lambda n: -sum(
            e - s for nm, s, e in rows if nm == n)):
        durs = [(e - s) / 1000.0 for nm, s, e in rows if nm == name]
        print('    %-40s %7.2f us x%.1f  (median %.2f)'
              % (name[:40], sum(durs) / top, counts[name] / float(top),
                 median(durs)))

    if runcsv:
        try:
            with open(runcsv) as f:
                hdr = f.readline().strip().split(',')
                idx = hdr.index('fft_exec_us') if 'fft_exec_us' in hdr else 5
                vals = []
                for line in f:
                    p = line.strip().split(',')
                    if len(p) > idx:
                        try:
                            vals.append(float(p[idx]))
                        except ValueError:
                            pass
            if vals:
                ev = median(vals)
                busy = busy_ns / 1000.0 / top
                print('  CUDA-event transform (this run) : %8.2f us' % ev)
                print('  gap between kernels             : %8.2f us  (%.0f%% of event time)'
                      % (ev - busy, 100.0 * (ev - busy) / ev if ev else 0))
        except (OSError, ValueError, IndexError):
            pass


main()
