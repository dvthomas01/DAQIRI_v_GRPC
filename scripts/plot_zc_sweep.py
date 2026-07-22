#!/usr/bin/env python3
"""Aggregate + chart the copy-vs-zero-copy sweep from zc_sweep.sh.

Reads data/zcs_<mode>_<BS>_<trial>.csv (mode in {copy, zerocopy}), computes
per-trial p50s, then the median-of-trials for each (size, mode).  Prints a
comparison table and writes charts to data/figures/.
"""
import argparse
import glob
import os
import statistics

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

SIZES = [4096, 8192, 16384, 32768]
BUF_LABELS = ["4K\n(16KB)", "8K\n(32KB)", "16K\n(64KB)", "32K\n(128KB)"]
MODES = ["copy", "zerocopy"]

COLOR_COPY = "#DD8452"
COLOR_ZC   = "#55A868"
LABELS = {"copy": "Copy (staging + cudaMemcpy)",
          "zerocopy": "Zero-copy (coherent in-place)"}


def p50(vals):
    s = sorted(v for v in vals if v == v)
    return s[len(s) // 2] if s else float("nan")


def trial_stats(path):
    try:
        df = pd.read_csv(path)
    except Exception:
        return None
    if df.empty:
        return None
    out = dict(rows=len(df))
    out["transfer"] = p50(df["transfer_latency_us"].tolist())
    out["e2e"] = p50(df["e2e_latency_us"].tolist())
    out["fft"] = p50(df["fft_exec_us"].tolist())
    out["mbps"] = p50(df["mb_per_sec"].tolist())
    if "e2e_latency_us" in df:
        e = df["e2e_latency_us"]
        out["e2e_p95"] = float(np.percentile(e, 95))
        out["e2e_p99"] = float(np.percentile(e, 99))
    return out


def med(xs):
    xs = [x for x in xs if x == x]
    return statistics.median(xs) if xs else float("nan")


def aggregate(data_dir):
    summary = {}
    for bs in SIZES:
        for mode in MODES:
            paths = sorted(glob.glob(os.path.join(data_dir, f"zcs_{mode}_{bs}_*.csv")))
            st = [s for s in (trial_stats(p) for p in paths) if s]
            if not st:
                continue
            summary[(bs, mode)] = dict(
                trials=len(st),
                deliv=med([s["rows"] for s in st]),
                transfer=med([s["transfer"] for s in st]),
                e2e=med([s["e2e"] for s in st]),
                e2e_p95=med([s["e2e_p95"] for s in st]),
                e2e_p99=med([s["e2e_p99"] for s in st]),
                fft=med([s["fft"] for s in st]),
                mbps=med([s["mbps"] for s in st]),
            )
    return summary


def print_table(summary):
    print(f"{'BS':>6} {'mode':>9} {'trials':>6} {'deliv':>6} "
          f"{'XFER_p50':>8} {'E2E_p50':>8} {'E2E_p95':>8} {'FFT_p50':>8} {'MB/s':>9}")
    for bs in SIZES:
        for mode in MODES:
            s = summary.get((bs, mode))
            if not s:
                continue
            print(f"{bs:>6} {mode:>9} {s['trials']:>6} {int(s['deliv']):>6} "
                  f"{s['transfer']:>8.2f} {s['e2e']:>8.2f} {s['e2e_p95']:>8.2f} "
                  f"{s['fft']:>8.2f} {s['mbps']:>9.1f}")
    print("\n=== zero-copy vs copy (median-of-trials) ===")
    for bs in SIZES:
        c = summary.get((bs, "copy"))
        z = summary.get((bs, "zerocopy"))
        if not c or not z:
            continue
        de = (z["e2e"] - c["e2e"]) / c["e2e"] * 100
        print(f"  BS={bs:>6}: E2E copy={c['e2e']:7.2f}us  zero-copy={z['e2e']:7.2f}us "
              f"({de:+6.1f}%)   XFER copy={c['transfer']:6.2f} -> zc={z['transfer']:.2f}")


def bars(ax, x, w, cvals, zvals, ylabel, title):
    ax.bar(x - w / 2, cvals, w, label=LABELS["copy"], color=COLOR_COPY, alpha=0.9)
    ax.bar(x + w / 2, zvals, w, label=LABELS["zerocopy"], color=COLOR_ZC, alpha=0.9)
    ax.set_xticks(x)
    ax.set_xticklabels(BUF_LABELS)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(axis="y", alpha=0.3)


def chart(summary, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    x = np.arange(len(SIZES))
    w = 0.38

    def series(mode, key):
        return [summary.get((bs, mode), {}).get(key, 0) for bs in SIZES]

    # Fig 1: E2E p50 + transfer p50 (headline)
    fig, axes = plt.subplots(1, 2, figsize=(13, 5.2))
    bars(axes[0], x, w, series("copy", "e2e"), series("zerocopy", "e2e"),
         "E2E latency p50 (us)", "Server-side end-to-end latency (p50)")
    bars(axes[1], x, w, series("copy", "transfer"), series("zerocopy", "transfer"),
         "Transfer latency p50 (us)", "H->D transfer latency (p50)")
    axes[0].legend()
    fig.suptitle("Pipeline B (shmem): copy vs zero-copy — median of 3 trials", fontweight="bold")
    fig.tight_layout()
    p1 = os.path.join(out_dir, "fig_zc_01_latency.png")
    fig.savefig(p1, dpi=130)
    plt.close(fig)

    # Fig 2: throughput + E2E tail (p95)
    fig, axes = plt.subplots(1, 2, figsize=(13, 5.2))
    bars(axes[0], x, w, series("copy", "mbps"), series("zerocopy", "mbps"),
         "Throughput (MB/s)", "Throughput (p50)")
    bars(axes[1], x, w, series("copy", "e2e_p95"), series("zerocopy", "e2e_p95"),
         "E2E latency p95 (us)", "End-to-end latency tail (p95)")
    axes[0].legend()
    fig.suptitle("Pipeline B (shmem): copy vs zero-copy — throughput & tail", fontweight="bold")
    fig.tight_layout()
    p2 = os.path.join(out_dir, "fig_zc_02_throughput_tail.png")
    fig.savefig(p2, dpi=130)
    plt.close(fig)
    return [p1, p2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data")
    ap.add_argument("--out", default="data/figures")
    args = ap.parse_args()
    summary = aggregate(args.data)
    if not summary:
        print("no zcs_*.csv trial files found in", args.data)
        return
    print_table(summary)
    figs = chart(summary, args.out)
    print("\nwrote:", *figs, sep="\n  ")


if __name__ == "__main__":
    main()
