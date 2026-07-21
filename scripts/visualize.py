#!/usr/bin/env python3
"""
visualize.py — Generate benchmark visualisation figures from CSV run data.

Works at any project phase:
  Phase 1  (DAQiri only)  : pass --daqiri path
  Phase 2  (gRPC only)    : pass --grpc path
  Phase 3  (both)         : pass both; comparison figures are also generated

Generated figures (saved to data/figures/):
  latency_cdf_<pipeline>.png         — CDF of E2E latency
  latency_cdf_comparison.png         — Both CDFs overlaid (Phase 3 only)
  latency_breakdown_<pipeline>.png   — Stacked bar: transfer + FFT + overhead
  latency_boxplot_<pipeline>.png     — Box plot per buffer size
  percentile_bars.png                — p50 / p95 / p99 grouped bars by buf size
  throughput_vs_bufsize.png          — MB/s vs buffer size (line chart)
  jitter_by_bufsize.png              — p99-p50 jitter bars
  utilization_<pipeline>.png         — CPU / GPU % over buffer index
  comparison_summary.png             — Side-by-side key-metric table (Phase 3)

Usage:
  python3 scripts/visualize.py
  python3 scripts/visualize.py --daqiri data/daqiri_results.csv
  python3 scripts/visualize.py --daqiri D.csv --grpc G.csv
  python3 scripts/visualize.py --out-dir results/figures
"""

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")   # headless — Spark has no display
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from matplotlib.gridspec import GridSpec

# ── Style ──────────────────────────────────────────────────────────────────

COLORS = {
    "daqiri":      "#76b900",   # NVIDIA green
    "grpc direct": "#0074b8",   # NI blue
}
FALLBACK_COLORS = ["#e07b39", "#9b59b6", "#1abc9c"]

plt.rcParams.update({
    "figure.dpi":        150,
    "axes.spines.top":   False,
    "axes.spines.right": False,
    "font.size":         11,
    "axes.titlesize":    13,
    "axes.labelsize":    11,
    "legend.fontsize":   10,
    "xtick.labelsize":   9,
    "ytick.labelsize":   9,
    "axes.grid":         True,
    "grid.alpha":        0.3,
    "grid.linewidth":    0.6,
})

# ── I/O helpers ────────────────────────────────────────────────────────────

def load_csv(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    # Back-fill throughput if only raw columns are present
    if "mb_per_sec" not in df.columns:
        if "samples_per_sec" in df.columns:
            df["mb_per_sec"] = df["samples_per_sec"] * 4.0 / 1e6
        elif "buffer_size_samples" in df.columns and "buffers_per_sec" in df.columns:
            df["mb_per_sec"] = df["buffer_size_samples"] * 4.0 * df["buffers_per_sec"] / 1e6
    return df


def save_fig(fig: plt.Figure, name: str, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / name
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved  {path}")


def pct(series: pd.Series, p: float) -> float:
    return float(np.percentile(series.dropna().values, p))


def buf_kb_label(n_samples: int) -> str:
    return f"{n_samples * 4 // 1024} KB"


# ── Individual plot functions ───────────────────────────────────────────────

def fig_latency_cdf(datasets, ax=None):
    """CDF of E2E latency for one or more pipelines."""
    own = ax is None
    if own:
        fig, ax = plt.subplots(figsize=(8, 4.5))
    else:
        fig = ax.figure

    for label, df, color in datasets:
        data = np.sort(df["e2e_latency_us"].dropna().values)
        if len(data) == 0:
            continue
        cdf = np.arange(1, len(data) + 1) / len(data) * 100
        ax.plot(data, cdf, color=color, linewidth=1.8, label=label)

    for p, ls in [(50, "--"), (95, ":"), (99, "-.")]:
        ax.axhline(p, color="grey", linewidth=0.7, linestyle=ls, alpha=0.6,
                   label=f"p{p}" if p == 50 else None)

    ax.set_xlabel("E2E Latency (µs)")
    ax.set_ylabel("Percentile (%)")
    ax.set_title("E2E Latency CDF")
    ax.yaxis.set_major_formatter(ticker.PercentFormatter())
    ax.legend()
    return fig if own else None


def fig_latency_breakdown(df, label, color):
    """Stacked horizontal bar: mean transfer + FFT exec + other overhead."""
    cols_present = [c for c in ("transfer_latency_us", "fft_exec_us") if c in df.columns]
    means = {c: df[c].mean() for c in cols_present}
    e2e   = df["e2e_latency_us"].mean()
    other = max(0.0, e2e - sum(means.values()))

    segments = list(means.items()) + [("other_overhead_us", other)]
    seg_colors = ["#5b9bd5", "#ed7d31", "#a9d18e", "#c5a0c8"]
    seg_labels = {
        "transfer_latency_us": "Transfer",
        "fft_exec_us":         "cuFFT exec",
        "other_overhead_us":   "Other",
    }

    fig, ax = plt.subplots(figsize=(7, 2.8))
    left = 0.0
    for (key, val), bc in zip(segments, seg_colors):
        ax.barh([label], [val], left=left, color=bc, alpha=0.85,
                label=seg_labels.get(key, key))
        if val > 0.5:
            ax.text(left + val / 2, 0, f"{val:.1f} µs",
                    ha="center", va="center", fontsize=8, color="white",
                    fontweight="bold")
        left += val

    ax.set_xlabel("Mean Latency (µs)")
    ax.set_title(f"Latency Breakdown — {label}")
    ax.legend(loc="lower right", fontsize=8)
    ax.set_xlim(0, e2e * 1.15)
    return fig


def fig_boxplot_per_bufsize(df, label, color):
    """Box plot of E2E latency grouped by buffer size."""
    if "buffer_size_samples" not in df.columns:
        return None
    bufsizes = sorted(df["buffer_size_samples"].unique())
    data     = [df[df["buffer_size_samples"] == bs]["e2e_latency_us"].dropna().values
                for bs in bufsizes]
    xlabels  = [buf_kb_label(bs) for bs in bufsizes]

    fig, ax = plt.subplots(figsize=(8, 5))
    bp = ax.boxplot(data, labels=xlabels, patch_artist=True,
                    medianprops=dict(color="black", linewidth=1.5),
                    flierprops=dict(marker=".", markersize=3, alpha=0.5))
    for patch in bp["boxes"]:
        patch.set_facecolor(color)
        patch.set_alpha(0.6)
    ax.set_xlabel("Buffer size")
    ax.set_ylabel("E2E Latency (µs)")
    ax.set_title(f"Latency Distribution by Buffer Size — {label}")
    return fig


def fig_percentile_bars(datasets):
    """Three grouped-bar subplots: p50 / p95 / p99 by buffer size."""
    all_bufsizes = sorted({
        bs for _, df, _ in datasets
        if "buffer_size_samples" in df.columns
        for bs in df["buffer_size_samples"].unique()
    })
    if not all_bufsizes:
        return None

    fig, axes = plt.subplots(1, 3, figsize=(13, 4.5), sharey=False)
    width = 0.8 / max(len(datasets), 1)
    x     = np.arange(len(all_bufsizes))

    for ax, (pname, pval) in zip(axes, [("p50", 50), ("p95", 95), ("p99", 99)]):
        for i, (label, df, color) in enumerate(datasets):
            if "buffer_size_samples" not in df.columns:
                continue
            vals = []
            for bs in all_bufsizes:
                sub = df[df["buffer_size_samples"] == bs]["e2e_latency_us"].dropna()
                vals.append(pct(sub, pval) if len(sub) else 0.0)
            offset = (i - (len(datasets) - 1) / 2) * width
            ax.bar(x + offset, vals, width * 0.9, color=color, alpha=0.85, label=label)
        ax.set_title(f"E2E {pname.upper()}")
        ax.set_xticks(x)
        ax.set_xticklabels([buf_kb_label(bs) for bs in all_bufsizes])
        ax.set_xlabel("Buffer size")
        ax.set_ylabel("Latency (µs)")
        ax.legend(fontsize=8)

    fig.suptitle("Latency Percentiles by Buffer Size", fontsize=13, y=1.02)
    fig.tight_layout()
    return fig


def fig_throughput_vs_bufsize(datasets):
    """Line chart: MB/s vs buffer size for each pipeline."""
    has_data = any(
        "buffer_size_samples" in df.columns and "mb_per_sec" in df.columns
        for _, df, _ in datasets
    )
    if not has_data:
        return None

    fig, ax = plt.subplots(figsize=(8, 4.5))
    for label, df, color in datasets:
        if "buffer_size_samples" not in df.columns or "mb_per_sec" not in df.columns:
            continue
        grp = (df.groupby("buffer_size_samples")["mb_per_sec"]
                 .mean()
                 .reset_index()
                 .sort_values("buffer_size_samples"))
        ax.plot(grp["buffer_size_samples"] * 4 / 1024,
                grp["mb_per_sec"],
                marker="o", linewidth=1.8, markersize=6,
                color=color, alpha=0.9, label=label)
    ax.set_xlabel("Buffer size (KB)")
    ax.set_ylabel("Throughput (MB/s)")
    ax.set_title("Throughput vs Buffer Size")
    ax.legend()
    return fig


def fig_jitter(datasets):
    """Grouped bar chart: p99−p50 jitter by buffer size."""
    all_bufsizes = sorted({
        bs for _, df, _ in datasets
        if "buffer_size_samples" in df.columns
        for bs in df["buffer_size_samples"].unique()
    })
    if not all_bufsizes:
        return None

    fig, ax = plt.subplots(figsize=(8, 4.5))
    width = 0.8 / max(len(datasets), 1)
    x     = np.arange(len(all_bufsizes))

    for i, (label, df, color) in enumerate(datasets):
        if "buffer_size_samples" not in df.columns:
            continue
        jitter = []
        for bs in all_bufsizes:
            sub = df[df["buffer_size_samples"] == bs]["e2e_latency_us"].dropna()
            jitter.append(pct(sub, 99) - pct(sub, 50) if len(sub) >= 2 else 0.0)
        offset = (i - (len(datasets) - 1) / 2) * width
        ax.bar(x + offset, jitter, width * 0.9, color=color, alpha=0.85, label=label)

    ax.set_xticks(x)
    ax.set_xticklabels([buf_kb_label(bs) for bs in all_bufsizes])
    ax.set_xlabel("Buffer size")
    ax.set_ylabel("Jitter p99 − p50 (µs)")
    ax.set_title("Jitter by Buffer Size")
    ax.legend()
    return fig


def fig_utilization(df, label, color):
    """Line chart: CPU + GPU utilization over buffer index."""
    has_cpu = "cpu_util_pct" in df.columns
    has_gpu = "gpu_util_pct" in df.columns
    if not has_cpu and not has_gpu:
        return None

    fig, ax = plt.subplots(figsize=(10, 4))
    idx = np.arange(len(df))
    if has_cpu:
        ax.plot(idx, df["cpu_util_pct"], color="#5b9bd5", linewidth=1.2,
                alpha=0.85, label="CPU %")
    if has_gpu:
        ax.plot(idx, df["gpu_util_pct"], color="#ed7d31", linewidth=1.2,
                alpha=0.85, label="GPU %")
    ax.set_xlabel("Buffer index")
    ax.set_ylabel("Utilisation (%)")
    ax.set_ylim(0, 105)
    ax.set_title(f"CPU / GPU Utilisation — {label}")
    ax.legend()
    return fig


def fig_fft_exec_cdf(datasets):
    """CDF of cuFFT kernel execution time across pipelines."""
    if not any("fft_exec_us" in df.columns for _, df, _ in datasets):
        return None
    fig, ax = plt.subplots(figsize=(8, 4.5))
    for label, df, color in datasets:
        if "fft_exec_us" not in df.columns:
            continue
        data = np.sort(df["fft_exec_us"].dropna().values)
        cdf  = np.arange(1, len(data) + 1) / len(data) * 100
        ax.plot(data, cdf, color=color, linewidth=1.8, label=label)
    ax.set_xlabel("cuFFT Exec Time (µs)")
    ax.set_ylabel("Percentile (%)")
    ax.set_title("cuFFT Execution Time CDF")
    ax.yaxis.set_major_formatter(ticker.PercentFormatter())
    ax.legend()
    return fig


def fig_comparison_summary(datasets):
    """Table figure: key metrics side by side (Phase 3 only)."""
    if len(datasets) < 2:
        return None

    rows_def = [
        ("E2E p50 (µs)",         "e2e_latency_us",      50),
        ("E2E p95 (µs)",         "e2e_latency_us",      95),
        ("E2E p99 (µs)",         "e2e_latency_us",      99),
        ("Jitter p99−p50 (µs)",  "e2e_latency_us",      None),   # special
        ("Transfer p50 (µs)",    "transfer_latency_us", 50),
        ("cuFFT exec p50 (µs)",  "fft_exec_us",         50),
        ("Throughput p50 (MB/s)","mb_per_sec",           50),
        ("CPU util mean (%)",    "cpu_util_pct",         None),   # mean
        ("GPU util mean (%)",    "gpu_util_pct",         None),   # mean
    ]

    col_labels = ["Metric"] + [label for label, _, _ in datasets]
    table_data = []
    for row_name, col, pval in rows_def:
        row = [row_name]
        for _, df, _ in datasets:
            if col not in df.columns:
                row.append("—")
                continue
            d = df[col].dropna()
            if len(d) == 0:
                row.append("—")
            elif pval is None and row_name.startswith("Jitter"):
                row.append(f"{pct(d,99) - pct(d,50):.2f}")
            elif pval is None:
                row.append(f"{d.mean():.2f}")
            else:
                row.append(f"{pct(d, pval):.2f}")
        table_data.append(row)

    fig, ax = plt.subplots(figsize=(9, len(rows_def) * 0.6 + 1.8))
    ax.axis("off")
    tbl = ax.table(cellText=table_data, colLabels=col_labels,
                   cellLoc="center", loc="center")
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(10)
    tbl.scale(1, 1.65)

    # Header row styling
    n_cols = len(col_labels)
    for j in range(n_cols):
        tbl[0, j].set_facecolor("#1a1a2e")
        tbl[0, j].set_text_props(color="white", fontweight="bold")

    # Data row styling — pipeline columns get their brand color, lightly
    for i in range(1, len(rows_def) + 1):
        tbl[i, 0].set_facecolor("#f0f0f0")   # metric name column
        for j, (_, _, color) in enumerate(datasets, start=1):
            tbl[i, j].set_facecolor(color + "22")   # ~13% opacity hex suffix

    ax.set_title("Pipeline Comparison — Key Metrics", fontsize=13,
                 fontweight="bold", pad=12)
    return fig


# ── Main ───────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate benchmark visualisation figures from CSV data.")
    parser.add_argument("--daqiri",  default="data/daqiri_results.csv",
                        help="DAQiri pipeline CSV  (default: data/daqiri_results.csv)")
    parser.add_argument("--grpc",    default="data/grpc_results.csv",
                        help="gRPC Direct pipeline CSV  (default: data/grpc_results.csv)")
    parser.add_argument("--out-dir", default="data/figures",
                        help="Output directory for figures  (default: data/figures)")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)

    # Build dataset list
    _fallback = iter(FALLBACK_COLORS)
    raw_inputs = [
        (args.daqiri, "DAQiri",      COLORS["daqiri"]),
        (args.grpc,   "gRPC Direct", COLORS["grpc direct"]),
    ]
    datasets = []
    for path, label, color in raw_inputs:
        if os.path.isfile(path):
            print(f"Loading {path} ...")
            datasets.append((label, load_csv(path), color))
        else:
            print(f"  (skipping '{path}' — file not found)")

    if not datasets:
        print("\nNo CSV data found. Run a benchmark first, then re-run this script.")
        sys.exit(1)

    print(f"\nGenerating figures → {out_dir}/\n")

    for label, df, color in datasets:
        tag = label.lower().replace(" ", "_")

        # 1. Latency CDF (single pipeline)
        f = fig_latency_cdf([(label, df, color)])
        if f: save_fig(f, f"latency_cdf_{tag}.png", out_dir)

        # 2. Latency breakdown stacked bar
        f = fig_latency_breakdown(df, label, color)
        if f: save_fig(f, f"latency_breakdown_{tag}.png", out_dir)

        # 3. Box plot per buffer size
        f = fig_boxplot_per_bufsize(df, label, color)
        if f: save_fig(f, f"latency_boxplot_{tag}.png", out_dir)

        # 4. cuFFT exec CDF (single pipeline)
        f = fig_fft_exec_cdf([(label, df, color)])
        if f: save_fig(f, f"fft_exec_cdf_{tag}.png", out_dir)

        # 5. CPU/GPU utilisation
        f = fig_utilization(df, label, color)
        if f: save_fig(f, f"utilization_{tag}.png", out_dir)

    # Multi-pipeline figures
    if len(datasets) >= 2:
        # Overlaid latency CDF
        f, ax = plt.subplots(figsize=(8, 4.5))
        fig_latency_cdf(datasets, ax=ax)
        save_fig(f, "latency_cdf_comparison.png", out_dir)

        # cuFFT exec CDF overlaid
        f = fig_fft_exec_cdf(datasets)
        if f: save_fig(f, "fft_exec_cdf_comparison.png", out_dir)

        # Comparison summary table
        f = fig_comparison_summary(datasets)
        if f: save_fig(f, "comparison_summary.png", out_dir)

    # Buffer-sweep figures (work with 1 or 2 pipelines)
    f = fig_percentile_bars(datasets)
    if f: save_fig(f, "percentile_bars.png", out_dir)

    f = fig_throughput_vs_bufsize(datasets)
    if f: save_fig(f, "throughput_vs_bufsize.png", out_dir)

    f = fig_jitter(datasets)
    if f: save_fig(f, "jitter_by_bufsize.png", out_dir)

    print(f"\nDone — {len(list(out_dir.glob('*.png')))} figure(s) in {out_dir}/")


if __name__ == "__main__":
    main()
