#!/usr/bin/env python3
"""Quick sanity check of the wire_latency_us column in a matched CSV."""
import csv, glob, os, statistics, sys

path = sys.argv[1] if len(sys.argv) > 1 else None
if not path:
    cands = sorted(glob.glob(os.path.expanduser("~/daqiri_gpu/data/mc_*.csv")),
                   key=os.path.getmtime)
    path = cands[-1] if cands else None
if not path:
    print("no CSV found")
    sys.exit(1)

rows = list(csv.DictReader(open(path)))
print("FILE:", os.path.basename(path), "rows:", len(rows))
print("COLUMNS:", list(rows[0].keys()) if rows else [])
wvals = [float(r.get("wire_latency_us", 0) or 0) for r in rows]
pos = [w for w in wvals if w > 0]
neg = [w for w in wvals if w <= 0]
print(f"wire: n_pos={len(pos)} n_nonpos={len(neg)}")
if pos:
    s = sorted(pos)
    print(f"wire_us  p50={s[len(s)//2]:.2f}  p95={s[int(len(s)*0.95)]:.2f}"
          f"  min={s[0]:.2f}  max={s[-1]:.2f}")
print("first 5 wire vals:", [round(w, 2) for w in wvals[:5]])
