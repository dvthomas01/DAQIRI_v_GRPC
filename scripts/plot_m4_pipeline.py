#!/usr/bin/env python3
"""
scripts/plot_m4_pipeline.py — M4 DAQiri pipeline benchmark visualization.

Reads per-buffer CSV files produced by bench_daqiri_pipeline for all 4
buffer sizes and generates:

  1.  latency_breakdown_<bufsize>.png  — stacked bar: H→D / FFT / overhead
  2.  e2e_cdf_all.png                  — E2E CDF for all 4 buffer sizes
  3.  throughput_vs_bufsize.png        — MB/s vs buffer size (log x-axis)
  4.  fft_latency_vs_bufsize.png       — FFT p50/p95/p99 vs buffer size
  5.  h2d_latency_vs_bufsize.png       — H→D p50/p95/p99 vs buffer size
  6.  jitter_vs_bufsize.png            — (p99-p50) vs buffer size
  7.  latency_violin_all.png           — violin plot of E2E across buffer sizes
  8.  pipeline_breakdown_stacked.png   — stacked area: H→D + FFT + overhead

Usage:
    python3 scripts/plot_m4_pipeline.py \
        --data data/ \
        --out  data/figures/
"""

import argparse
import os
import sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

# ── Style ────────────────────────────────────────────────────────────────────
plt.rcParams.update({
    "figure.dpi": 150,
    "axes.grid": True,
    "grid.alpha": 0.35,
    "font.size": 11,
    "axes.titlesize": 13,
    "axes.labelsize": 11,
})
PALETTE = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728"]
BUF_SIZES = [4096, 8192, 16384, 32768]


def load_csvs(data_dir: str) -> dict[int, pd.DataFrame]:
    dfs = {}
    for bs in BUF_SIZES:
        path = os.path.join(data_dir, f"daqiri_pipeline_{bs}.csv")
        if not os.path.exists(path):
            print(f"  [warn] missing {path} — skipping", file=sys.stderr)
            continue
        df = pd.read_csv(path)
        dfs[bs] = df
        print(f"  loaded {path}  ({len(df)} rows)")
    return dfs


def pct(series, p):
    return float(np.percentile(series, p))


# ── Figure 1: E2E CDF (all buffer sizes, one curve each) ────────────────────
def plot_e2e_cdf(dfs, out_dir):
    fig, ax = plt.subplots(figsize=(8, 5))
    for (bs, df), color in zip(sorted(dfs.items()), PALETTE):
        vals = np.sort(df["e2e_latency_us"].values)
        cdf = np.arange(1, len(vals) + 1) / len(vals)
        ax.plot(vals, cdf * 100, label=f"{bs // 1024} KB", color=color, lw=1.8)
    ax.axhline(50, ls="--", color="gray", lw=0.8, alpha=0.7)
    ax.axhline(95, ls=":",  color="gray", lw=0.8, alpha=0.7)
    ax.axhline(99, ls="-.", color="gray", lw=0.8, alpha=0.7)
    ax.set_xlabel("E2E Latency (µs)")
    ax.set_ylabel("Percentile (%)")
    ax.set_title("DAQiri Pipeline — E2E Latency CDF (all buffer sizes)")
    ax.legend(title="Buffer size")
    ax.set_ylim(0, 101)
    fig.tight_layout()
    path = os.path.join(out_dir, "e2e_cdf_all.png")
    fig.savefig(path); plt.close(fig)
    print(f"  wrote {path}")


# ── Figure 2: Throughput vs buffer size ─────────────────────────────────────
def plot_throughput_vs_bufsize(dfs, out_dir):
    sizes, throughputs = [], []
    for bs in sorted(dfs):
        df = dfs[bs]
        sizes.append(bs)
        throughputs.append(float(df["mb_per_sec"].mean()))

    fig, ax = plt.subplots(figsize=(7, 4))
    ax.plot([s // 1024 for s in sizes], throughputs,
            "o-", color=PALETTE[0], lw=2, ms=8)
    for x, y in zip(sizes, throughputs):
        ax.annotate(f"{y:.1f}", (x // 1024, y),
                    textcoords="offset points", xytext=(5, 5), fontsize=9)
    ax.set_xlabel("Buffer size (KB)")
    ax.set_ylabel("Mean throughput (MB/s)")
    ax.set_title("DAQiri Pipeline — Throughput vs Buffer Size")
    ax.set_xticks([s // 1024 for s in sizes])
    fig.tight_layout()
    path = os.path.join(out_dir, "throughput_vs_bufsize.png")
    fig.savefig(path); plt.close(fig)
    print(f"  wrote {path}")


# ── Figure 3: Latency percentile bars (H→D / FFT / overhead) ────────────────
def plot_latency_breakdown(dfs, out_dir):
    """Stacked bar: p50 of H→D, FFT, and overhead (e2e - h2d - fft) per size."""
    labels, h2d_p50, fft_p50, overhead_p50 = [], [], [], []
    for bs in sorted(dfs):
        df = dfs[bs]
        h = pct(df["transfer_latency_us"], 50)
        f = pct(df["fft_exec_us"], 50)
        e = pct(df["e2e_latency_us"], 50)
        labels.append(f"{bs // 1024} KB")
        h2d_p50.append(h)
        fft_p50.append(f)
        overhead_p50.append(max(0.0, e - h - f))

    x = np.arange(len(labels))
    w = 0.5
    fig, ax = plt.subplots(figsize=(7, 4.5))
    b1 = ax.bar(x, h2d_p50,   w, label="H→D copy",  color=PALETTE[0])
    b2 = ax.bar(x, fft_p50,   w, bottom=h2d_p50,
                label="cuFFT",    color=PALETTE[1])
    b3 = ax.bar(x, overhead_p50, w,
                bottom=[a + b for a, b in zip(h2d_p50, fft_p50)],
                label="Overhead", color=PALETTE[2], alpha=0.7)
    ax.set_xticks(x); ax.set_xticklabels(labels)
    ax.set_xlabel("Buffer size")
    ax.set_ylabel("p50 Latency (µs)")
    ax.set_title("DAQiri Pipeline — E2E Latency Breakdown (p50)")
    ax.legend()
    fig.tight_layout()
    path = os.path.join(out_dir, "latency_breakdown_stacked.png")
    fig.savefig(path); plt.close(fig)
    print(f"  wrote {path}")


# ── Figure 4: FFT latency percentiles vs buffer size ─────────────────────────
def plot_fft_vs_bufsize(dfs, out_dir):
    sizes_kb = [bs // 1024 for bs in sorted(dfs)]
    p50s = [pct(dfs[bs]["fft_exec_us"], 50) for bs in sorted(dfs)]
    p95s = [pct(dfs[bs]["fft_exec_us"], 95) for bs in sorted(dfs)]
    p99s = [pct(dfs[bs]["fft_exec_us"], 99) for bs in sorted(dfs)]

    fig, ax = plt.subplots(figsize=(7, 4))
    ax.plot(sizes_kb, p50s, "o-", label="p50", color=PALETTE[0], lw=1.8)
    ax.plot(sizes_kb, p95s, "s--", label="p95", color=PALETTE[1], lw=1.8)
    ax.plot(sizes_kb, p99s, "^:", label="p99", color=PALETTE[2], lw=1.8)
    ax.fill_between(sizes_kb, p50s, p99s, alpha=0.12, color=PALETTE[0])
    ax.set_xlabel("Buffer size (KB)")
    ax.set_ylabel("cuFFT Execution Time (µs)")
    ax.set_title("DAQiri Pipeline — cuFFT Latency vs Buffer Size")
    ax.set_xticks(sizes_kb)
    ax.legend()
    fig.tight_layout()
    path = os.path.join(out_dir, "fft_latency_vs_bufsize.png")
    fig.savefig(path); plt.close(fig)
    print(f"  wrote {path}")


# ── Figure 5: H→D latency percentiles vs buffer size ─────────────────────────
def plot_h2d_vs_bufsize(dfs, out_dir):
    sizes_kb = [bs // 1024 for bs in sorted(dfs)]
    p50s = [pct(dfs[bs]["transfer_latency_us"], 50) for bs in sorted(dfs)]
    p95s = [pct(dfs[bs]["transfer_latency_us"], 95) for bs in sorted(dfs)]
    p99s = [pct(dfs[bs]["transfer_latency_us"], 99) for bs in sorted(dfs)]

    fig, ax = plt.subplots(figsize=(7, 4))
    ax.plot(sizes_kb, p50s, "o-", label="p50", color=PALETTE[0], lw=1.8)
    ax.plot(sizes_kb, p95s, "s--", label="p95", color=PALETTE[1], lw=1.8)
    ax.plot(sizes_kb, p99s, "^:", label="p99", color=PALETTE[2], lw=1.8)
    ax.fill_between(sizes_kb, p50s, p99s, alpha=0.12, color=PALETTE[1])
    ax.set_xlabel("Buffer size (KB)")
    ax.set_ylabel("H→D Copy Latency (µs)")
    ax.set_title("DAQiri Pipeline — H→D Transfer Latency vs Buffer Size")
    ax.set_xticks(sizes_kb)
    ax.legend()
    fig.tight_layout()
    path = os.path.join(out_dir, "h2d_latency_vs_bufsize.png")
    fig.savefig(path); plt.close(fig)
    print(f"  wrote {path}")


# ── Figure 6: Jitter (p99 - p50) vs buffer size ──────────────────────────────
def plot_jitter(dfs, out_dir):
    sizes_kb = [bs // 1024 for bs in sorted(dfs)]
    jitters = [pct(dfs[bs]["e2e_latency_us"], 99)
               - pct(dfs[bs]["e2e_latency_us"], 50)
               for bs in sorted(dfs)]

    fig, ax = plt.subplots(figsize=(7, 4))
    ax.bar(sizes_kb, jitters, width=3, color=PALETTE[3], alpha=0.8)
    for x, y in zip(sizes_kb, jitters):
        ax.text(x, y + 0.2, f"{y:.1f} µs", ha="center", fontsize=9)
    ax.set_xlabel("Buffer size (KB)")
    ax.set_ylabel("Jitter — p99−p50 (µs)")
    ax.set_title("DAQiri Pipeline — E2E Jitter vs Buffer Size")
    ax.set_xticks(sizes_kb)
    fig.tight_layout()
    path = os.path.join(out_dir, "jitter_vs_bufsize.png")
    fig.savefig(path); plt.close(fig)
    print(f"  wrote {path}")


# ── Figure 7: Violin plot of E2E latency (all buffer sizes) ─────────────────
def plot_violin(dfs, out_dir):
    data = [dfs[bs]["e2e_latency_us"].values for bs in sorted(dfs)]
    labels = [f"{bs // 1024} KB" for bs in sorted(dfs)]

    fig, ax = plt.subplots(figsize=(8, 5))
    vp = ax.violinplot(data, positions=range(1, len(data) + 1),
                       showmedians=True, showextrema=True)
    for i, body in enumerate(vp["bodies"]):
        body.set_facecolor(PALETTE[i % len(PALETTE)])
        body.set_alpha(0.7)
    vp["cmedians"].set_color("black")
    ax.set_xticks(range(1, len(labels) + 1))
    ax.set_xticklabels(labels)
    ax.set_xlabel("Buffer size")
    ax.set_ylabel("E2E Latency (µs)")
    ax.set_title("DAQiri Pipeline — E2E Latency Distribution (Violin)")
    fig.tight_layout()
    path = os.path.join(out_dir, "latency_violin_all.png")
    fig.savefig(path); plt.close(fig)
    print(f"  wrote {path}")


# ── Figure 8: Per-buffer time-series for one run (4096, first 200 buffers) ──
def plot_timeseries(dfs, out_dir):
    if 4096 not in dfs:
        return
    df = dfs[4096].head(200)
    fig, axes = plt.subplots(3, 1, figsize=(10, 7), sharex=True)
    for ax, col, label, color in zip(
        axes,
        ["e2e_latency_us", "transfer_latency_us", "fft_exec_us"],
        ["E2E latency (µs)", "H→D latency (µs)", "cuFFT time (µs)"],
        PALETTE
    ):
        ax.plot(df.index, df[col], lw=1.0, color=color, alpha=0.85)
        ax.set_ylabel(label)
        ax.axhline(df[col].median(), ls="--", color="black", lw=0.8, alpha=0.6,
                   label=f"median={df[col].median():.1f}")
        ax.legend(loc="upper right", fontsize=9)
    axes[-1].set_xlabel("Buffer index")
    axes[0].set_title("DAQiri Pipeline — Per-buffer Latency Time-series (N=4096, first 200 buffers)")
    fig.tight_layout()
    path = os.path.join(out_dir, "latency_timeseries_4096.png")
    fig.savefig(path); plt.close(fig)
    print(f"  wrote {path}")


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="M4 DAQiri pipeline visualizer")
    ap.add_argument("--data", default="data",    help="directory with CSV files")
    ap.add_argument("--out",  default="data/figures", help="output directory for PNGs")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    print(f"Loading CSVs from {args.data}/")
    dfs = load_csvs(args.data)
    if not dfs:
        print("No CSV files found — exiting.", file=sys.stderr)
        sys.exit(1)

    print(f"\nGenerating figures → {args.out}/")
    plot_e2e_cdf(dfs, args.out)
    plot_throughput_vs_bufsize(dfs, args.out)
    plot_latency_breakdown(dfs, args.out)
    plot_fft_vs_bufsize(dfs, args.out)
    plot_h2d_vs_bufsize(dfs, args.out)
    plot_jitter(dfs, args.out)
    plot_violin(dfs, args.out)
    plot_timeseries(dfs, args.out)

    print("\nDone.")


if __name__ == "__main__":
    main()
