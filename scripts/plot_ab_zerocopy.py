#!/usr/bin/env python3
"""Final apples-to-apples comparison: Pipeline A (DAQiri) vs Pipeline B (gRPC
Direct), each in copy and zero-copy mode.

Reads the two sweeps' trial CSVs:
  data/dqzc_<mode>_<BS>_<trial>.csv   (DAQiri  : mode in {copy, zerocopy})
  data/zcs_<mode>_<BS>_<trial>.csv    (gRPC    : mode in {copy, zerocopy})

Computes per-trial p50s -> median-of-trials per (size, pipeline, mode), prints a
table, and writes charts to data/figures/.
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

LABELS = {
    ("daqiri", "copy"):     ("DAQiri — copy",           "#C44E52"),
    ("daqiri", "zerocopy"): ("DAQiri — zero-copy",      "#4C72B0"),
    ("grpc",   "copy"):     ("gRPC Direct — copy",      "#DD8452"),
    ("grpc",   "zerocopy"): ("gRPC Direct — zero-copy", "#55A868"),
}
# tag -> {(pipeline, mode): glob-prefix}
PREFIXES = {
    "paced": {
        ("daqiri", "copy"): "dqzc_copy", ("daqiri", "zerocopy"): "dqzc_zerocopy",
        ("grpc", "copy"): "zcs_copy",   ("grpc", "zerocopy"): "zcs_zerocopy",
    },
    "airtight": {
        ("daqiri", "copy"): "ab_daqiri_copy", ("daqiri", "zerocopy"): "ab_daqiri_zerocopy",
        ("grpc", "copy"): "ab_grpc_copy",     ("grpc", "zerocopy"): "ab_grpc_zerocopy",
    },
}
SERIES = {}  # populated in main() from the chosen tag
ORDER = [("daqiri", "copy"), ("grpc", "copy"),
         ("daqiri", "zerocopy"), ("grpc", "zerocopy")]


def p50(xs):
    s = sorted(v for v in xs if v == v)
    return s[len(s) // 2] if s else float("nan")


def trial_stats(path):
    try:
        df = pd.read_csv(path)
    except Exception:
        return None
    if df.empty:
        return None
    return dict(
        rows=len(df),
        transfer=p50(df["transfer_latency_us"].tolist()),
        e2e=p50(df["e2e_latency_us"].tolist()),
        e2e_p95=float(np.percentile(df["e2e_latency_us"], 95)),
        fft=p50(df["fft_exec_us"].tolist()),
        mbps=p50(df["mb_per_sec"].tolist()),
    )


def med(xs):
    xs = [x for x in xs if x == x]
    return statistics.median(xs) if xs else float("nan")


def aggregate(data_dir):
    summary = {}
    for key, (prefix, _lbl, _col) in SERIES.items():
        for bs in SIZES:
            paths = sorted(glob.glob(os.path.join(data_dir, f"{prefix}_{bs}_*.csv")))
            st = [s for s in (trial_stats(p) for p in paths) if s]
            if not st:
                continue
            summary[(key, bs)] = dict(
                trials=len(st),
                deliv=med([s["rows"] for s in st]),
                transfer=med([s["transfer"] for s in st]),
                e2e=med([s["e2e"] for s in st]),
                e2e_p95=med([s["e2e_p95"] for s in st]),
                fft=med([s["fft"] for s in st]),
                mbps=med([s["mbps"] for s in st]),
            )
    return summary


def print_table(summary):
    print(f"{'BS':>6} {'pipeline/mode':>24} {'trials':>6} "
          f"{'XFER_p50':>8} {'E2E_p50':>8} {'E2E_p95':>8} {'FFT_p50':>8} {'MB/s':>9}")
    for bs in SIZES:
        for key in ORDER:
            s = summary.get((key, bs))
            if not s:
                continue
            lbl = SERIES[key][1]
            print(f"{bs:>6} {lbl:>24} {s['trials']:>6} "
                  f"{s['transfer']:>8.2f} {s['e2e']:>8.2f} {s['e2e_p95']:>8.2f} "
                  f"{s['fft']:>8.2f} {s['mbps']:>9.1f}")
    print("\n=== zero-copy head-to-head: DAQiri vs gRPC Direct (E2E p50) ===")
    for bs in SIZES:
        d = summary.get((("daqiri", "zerocopy"), bs))
        g = summary.get((("grpc", "zerocopy"), bs))
        if not d or not g:
            continue
        diff = (g["e2e"] - d["e2e"]) / d["e2e"] * 100
        print(f"  BS={bs:>6}: DAQiri={d['e2e']:6.2f}us  gRPC={g['e2e']:6.2f}us  "
              f"(gRPC {diff:+5.1f}% vs DAQiri)")


def grouped_bars(ax, summary, key_metric, ylabel, title):
    x = np.arange(len(SIZES))
    n = len(ORDER)
    w = 0.8 / n
    for i, key in enumerate(ORDER):
        vals = [summary.get((key, bs), {}).get(key_metric, 0) for bs in SIZES]
        off = (i - (n - 1) / 2) * w
        ax.bar(x + off, vals, w, label=SERIES[key][1], color=SERIES[key][2], alpha=0.9)
    ax.set_xticks(x)
    ax.set_xticklabels(BUF_LABELS)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(axis="y", alpha=0.3)


def _footnote_32768(summary):
    """Build the 32768 caveat string from the actual delivered-row medians."""
    dc = summary.get((("daqiri", "copy"), 32768), {}).get("deliv", float("nan"))
    dz = summary.get((("daqiri", "zerocopy"), 32768), {}).get("deliv", float("nan"))
    gc = summary.get((("grpc", "copy"), 32768), {}).get("deliv", float("nan"))
    return (
        "Note (32K / 128 KB): DAQiri's TCP-loopback transport drops buffers at max payload "
        f"(median delivered ~{dc:.0f} copy / ~{dz:.0f} zero-copy of ~900), while gRPC's "
        f"shmem transport delivers ~{gc:.0f}. p50 latency stays valid (100+ samples); "
        "treat the 32K throughput/tail bars as indicative only."
    )


def chart(summary, out_dir, tag="airtight"):
    os.makedirs(out_dir, exist_ok=True)
    foot = _footnote_32768(summary)
    # Fig 1: E2E p50 (all four) + transfer p50 (all four)
    fig, axes = plt.subplots(1, 2, figsize=(15, 5.8))
    grouped_bars(axes[0], summary, "e2e", "E2E latency p50 (us)",
                 "End-to-end latency (p50)")
    grouped_bars(axes[1], summary, "transfer", "Transfer latency p50 (us)",
                 "H->D transfer latency (p50)")
    axes[0].legend(fontsize=8)
    fig.suptitle("Pipeline A (DAQiri) vs Pipeline B (gRPC Direct): copy vs zero-copy "
                 "— median of trials (airtight, both paced 400us)", fontweight="bold")
    fig.tight_layout(rect=(0, 0.06, 1, 1))
    fig.text(0.5, 0.01, foot, ha="center", va="bottom", fontsize=8,
             color="#555555", wrap=True)
    p1 = os.path.join(out_dir, f"fig_ab_{tag}_01_latency.png")
    fig.savefig(p1, dpi=130)
    plt.close(fig)

    # Fig 2: zero-copy-only head-to-head (E2E p50 + throughput)
    zc_order = [("daqiri", "zerocopy"), ("grpc", "zerocopy")]
    x = np.arange(len(SIZES)); w = 0.38
    fig, axes = plt.subplots(1, 2, figsize=(13, 5.4))
    for i, key in enumerate(zc_order):
        e = [summary.get((key, bs), {}).get("e2e", 0) for bs in SIZES]
        m = [summary.get((key, bs), {}).get("mbps", 0) for bs in SIZES]
        off = (i - 0.5) * w
        axes[0].bar(x + off, e, w, label=SERIES[key][1], color=SERIES[key][2], alpha=0.9)
        axes[1].bar(x + off, m, w, label=SERIES[key][1], color=SERIES[key][2], alpha=0.9)
    for ax, yl, tt in ((axes[0], "E2E latency p50 (us)", "Zero-copy head-to-head: E2E latency (p50)"),
                       (axes[1], "Throughput (MB/s)", "Zero-copy head-to-head: throughput (p50)")):
        ax.set_xticks(x); ax.set_xticklabels(BUF_LABELS); ax.set_ylabel(yl)
        ax.set_title(tt); ax.grid(axis="y", alpha=0.3)
    axes[0].legend()
    fig.suptitle("Both pipelines zero-copy — true apples-to-apples", fontweight="bold")
    fig.tight_layout(rect=(0, 0.06, 1, 1))
    fig.text(0.5, 0.01, foot, ha="center", va="bottom", fontsize=8,
             color="#555555", wrap=True)
    p2 = os.path.join(out_dir, f"fig_ab_{tag}_02_zerocopy_headtohead.png")
    fig.savefig(p2, dpi=130)
    plt.close(fig)
    return [p1, p2]


def matched_pair_deltas(data_dir):
    """Clock-neutralised comparison: pair DAQiri vs gRPC per (mode, BS, trial)
    (they ran back-to-back on the same clock), delta = gRPC_p50 - DAQiri_p50,
    then median-of-trials. Removes common-mode clock drift."""
    print("\n=== matched-pair (clock-neutralised) E2E p50 delta: gRPC - DAQiri ===")
    for mode in ("copy", "zerocopy"):
        print(f"  -- {mode} --")
        for bs in SIZES:
            dp = SERIES[("daqiri", mode)][0]
            gp = SERIES[("grpc", mode)][0]
            deltas, rels = [], []
            t = 1
            while True:
                dpath = os.path.join(data_dir, f"{dp}_{bs}_{t}.csv")
                gpath = os.path.join(data_dir, f"{gp}_{bs}_{t}.csv")
                if not (os.path.exists(dpath) and os.path.exists(gpath)):
                    break
                ds, gs = trial_stats(dpath), trial_stats(gpath)
                if ds and gs:
                    deltas.append(gs["e2e"] - ds["e2e"])
                    rels.append((gs["e2e"] - ds["e2e"]) / ds["e2e"] * 100)
                t += 1
            if not deltas:
                continue
            print(f"    BS={bs:>6}: n={len(deltas)}  median delta={med(deltas):+7.2f}us "
                  f"({med(rels):+5.1f}%)  gRPC {'slower' if med(deltas) > 0 else 'faster'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data")
    ap.add_argument("--out", default="data/figures")
    ap.add_argument("--tag", default="airtight", choices=list(PREFIXES.keys()))
    args = ap.parse_args()
    global SERIES
    SERIES = {k: (PREFIXES[args.tag][k], LABELS[k][0], LABELS[k][1]) for k in LABELS}
    summary = aggregate(args.data)
    if not summary:
        print("no trial CSVs found in", args.data, "for tag", args.tag)
        return
    print_table(summary)
    matched_pair_deltas(args.data)
    figs = chart(summary, args.out, args.tag)
    print("\nwrote:", *figs, sep="\n  ")


if __name__ == "__main__":
    main()
