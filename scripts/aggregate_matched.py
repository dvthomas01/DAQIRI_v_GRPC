#!/usr/bin/env python3
"""Aggregate matched_compare trial CSVs into a fair standard-vs-shmem table.

Reads data/mc_<transport>_<BS>_<trial>.csv, computes per-trial p50s, then the
median-of-trials for each (size, transport).  Prints a comparison table.
"""
import csv, glob, os, statistics, sys

DATA = os.path.expanduser("~/daqiri_gpu/data")
SIZES = [4096, 8192, 16384, 32768]
TRANSPORTS = ["standard", "shmem"]


def p50(vals):
    s = sorted(vals)
    return s[len(s) // 2] if s else float("nan")


def trial_stats(path):
    rows = list(csv.DictReader(open(path)))
    if not rows:
        return None
    h2d = p50([float(r["transfer_latency_us"]) for r in rows])
    e2e = p50([float(r["e2e_latency_us"]) for r in rows])
    mbps = p50([float(r["mb_per_sec"]) for r in rows])
    # wire = client send_timestamp -> server receive (transport latency).
    # Drop non-positive values (missing timestamp or CLOCK_REALTIME jump).
    wvals = [float(r.get("wire_latency_us", 0) or 0) for r in rows]
    wvals = [w for w in wvals if w > 0]
    wire = p50(wvals) if wvals else float("nan")
    return dict(rows=len(rows), h2d=h2d, e2e=e2e, mbps=mbps, wire=wire)


def med(xs):
    return statistics.median(xs) if xs else float("nan")


print(f"{'BS':>6} {'transport':>9} {'trials':>6} {'deliv':>6} "
      f"{'WIRE_p50':>8} {'H2D_p50':>8} {'E2E_p50':>8} {'MB/s':>8}")
summary = {}
for bs in SIZES:
    for tr in TRANSPORTS:
        paths = sorted(glob.glob(f"{DATA}/mc_{tr}_{bs}_*.csv"))
        st = [trial_stats(p) for p in paths]
        st = [s for s in st if s]
        if not st:
            continue
        deliv = med([s["rows"] for s in st])
        h2d = med([s["h2d"] for s in st])
        e2e = med([s["e2e"] for s in st])
        mbps = med([s["mbps"] for s in st])
        wire = med([s["wire"] for s in st if s["wire"] == s["wire"]])
        summary[(bs, tr)] = dict(deliv=deliv, h2d=h2d, e2e=e2e, mbps=mbps, wire=wire)
        print(f"{bs:>6} {tr:>9} {len(st):>6} {int(deliv):>6} "
              f"{wire:>8.1f} {h2d:>8.1f} {e2e:>8.1f} {mbps:>8.1f}")

print("\n=== shmem vs standard (matched pace, median-of-trials) ===")
for bs in SIZES:
    s = summary.get((bs, "standard"))
    m = summary.get((bs, "shmem"))
    if not s or not m:
        continue
    dw = (m["wire"] - s["wire"]) / s["wire"] * 100
    print(f"  BS={bs:>6}: WIRE shmem={m['wire']:6.1f} vs std={s['wire']:6.1f} "
          f"({dw:+5.1f}%)  deliv shmem={int(m['deliv'])}/1000 std={int(s['deliv'])}/1000")
