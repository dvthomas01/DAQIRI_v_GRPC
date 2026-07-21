#!/usr/bin/env python3
"""
M6 — Nsight Systems profiling visualizer.

Reads:
  data/nsight/profile_<BS>_cuda_gpu_kern_sum.csv
  data/nsight/profile_<BS>_cuda_gpu_mem_time_sum.csv
  data/nsight/profile_<BS>_cuda_api_sum.csv
  data/daqiri_pipeline_<BS>.csv   (M5 CUDA-event measurements)

Generates 6 figures:
  fig_m6_01_cufft_kernels_heatmap.png  — per-kernel duration heatmap by buffer size
  fig_m6_02_cufft_avg_vs_events.png    — nsys avg vs CUDA-event p50 (FFT + H→D)
  fig_m6_03_top_kernels_bar.png        — top-5 kernels total time, stacked by size
  fig_m6_04_memops_breakdown.png       — H→D/D→H memop timing by buffer size
  fig_m6_05_api_overhead.png           — CUDA API call overhead (cudaMemcpy, cudaMalloc, etc.)
  fig_m6_06_gpu_time_fraction.png      — fraction of wall time spent in GPU kernels vs memops
"""

import argparse
import glob
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np
import pandas as pd

BUFFER_SIZES = [4096, 8192, 16384, 32768]
BUF_LABELS   = ["4K\n(16KB)", "8K\n(32KB)", "16K\n(64KB)", "32K\n(128KB)"]
BUF_BYTES    = {bs: bs * 4 for bs in BUFFER_SIZES}
PALETTE      = ["#4C72B0", "#DD8452", "#55A868", "#C44E52"]

# ── helpers ──────────────────────────────────────────────────────────────────

def load_kern_sum(path):
    """Load cuda_gpu_kern_sum CSV, normalise column names."""
    if not os.path.exists(path):
        return None
    df = pd.read_csv(path)
    df.columns = [c.strip() for c in df.columns]
    # Nsys may quote numbers with commas; strip them
    for col in df.columns:
        if col not in ("Name",):
            try:
                df[col] = df[col].astype(str).str.replace(",", "").astype(float)
            except Exception:
                pass
    return df


def load_memop_sum(path):
    if not os.path.exists(path):
        return None
    df = pd.read_csv(path)
    df.columns = [c.strip() for c in df.columns]
    for col in df.columns:
        if col not in ("Operation",):
            try:
                df[col] = df[col].astype(str).str.replace(",", "").astype(float)
            except Exception:
                pass
    return df


def load_api_sum(path):
    if not os.path.exists(path):
        return None
    df = pd.read_csv(path)
    df.columns = [c.strip() for c in df.columns]
    for col in df.columns:
        if col not in ("Name",):
            try:
                df[col] = df[col].astype(str).str.replace(",", "").astype(float)
            except Exception:
                pass
    return df


def load_m5_csv(path):
    if not os.path.exists(path):
        return None
    return pd.read_csv(path)


def get_avg(df, name_col, name_val, avg_col="Avg (ns)"):
    """Return Avg value (ns) for a row matching name_val (partial, case-insensitive)."""
    if df is None:
        return np.nan
    mask = df[name_col].str.contains(name_val, case=False, na=False, regex=False)
    if not mask.any():
        return np.nan
    # Try the given avg_col, fall back to 'Avg (ns)'
    col = avg_col if avg_col in df.columns else "Avg (ns)"
    return df.loc[mask, col].values[0]


def ns_to_us(v):
    return v / 1e3


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nsight", default="data/nsight")
    ap.add_argument("--m5data", default="data")
    ap.add_argument("--out",    default="data/figures")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)

    # ── load all data ──
    kern_dfs  = {}
    mem_dfs   = {}
    api_dfs   = {}
    m5_dfs    = {}

    for bs in BUFFER_SIZES:
        kern_dfs[bs] = load_kern_sum(
            os.path.join(args.nsight, f"profile_{bs}_cuda_gpu_kern_sum.csv"))
        mem_dfs[bs]  = load_memop_sum(
            os.path.join(args.nsight, f"profile_{bs}_cuda_gpu_mem_time_sum.csv"))
        api_dfs[bs]  = load_api_sum(
            os.path.join(args.nsight, f"profile_{bs}_cuda_api_sum.csv"))
        m5_dfs[bs]   = load_m5_csv(
            os.path.join(args.m5data, f"daqiri_pipeline_{bs}.csv"))

    loaded = [bs for bs in BUFFER_SIZES if kern_dfs[bs] is not None]
    if not loaded:
        print("[warn] No nsys kernel CSV files found — check data/nsight/ contents")
        print("       Files expected: profile_<BS>_cuda_gpu_kern_sum.csv")
        # Still attempt m5-only figures
    else:
        print(f"Loaded nsys data for buffer sizes: {loaded}")

    # ── Fig 1: cuFFT kernel avg duration heatmap ──────────────────────────────
    # Collect all unique kernel names that appear in any buffer size
    all_kern_names = set()
    for bs in loaded:
        df = kern_dfs[bs]
        if df is not None:
            all_kern_names.update(df["Name"].tolist())
    all_kern_names = sorted(all_kern_names)

    if all_kern_names and loaded:
        # Build matrix: rows=kernels, cols=buffer sizes
        matrix = np.full((len(all_kern_names), len(loaded)), np.nan)
        for ci, bs in enumerate(loaded):
            df = kern_dfs[bs]
            for ri, kname in enumerate(all_kern_names):
                row = df[df["Name"] == kname]
                if not row.empty:
                    avg_col = "Avg (ns)" if "Avg (ns)" in df.columns else "Avg"
                    matrix[ri, ci] = ns_to_us(row[avg_col].values[0])

        # Sort by total (sum across sizes, ignoring nan)
        row_totals = np.nansum(matrix, axis=1)
        order = np.argsort(row_totals)[::-1][:20]   # top-20 kernels
        matrix = matrix[order]
        names  = [all_kern_names[i] for i in order]
        # Shorten names for display
        short_names = []
        for n in names:
            # strip template params, keep first 45 chars
            n2 = re.sub(r'<[^>]*>', '', n)
            short_names.append(n2[:48])

        fig, ax = plt.subplots(figsize=(10, max(4, len(names)*0.35 + 1)))
        im = ax.imshow(matrix, aspect="auto", cmap="YlOrRd",
                       vmin=0, vmax=np.nanmax(matrix))
        ax.set_xticks(range(len(loaded)))
        ax.set_xticklabels([f"{bs//1024}K" if bs >= 1024 else str(bs)
                            for bs in loaded])
        ax.set_yticks(range(len(names)))
        ax.set_yticklabels(short_names, fontsize=7)
        ax.set_xlabel("Buffer size (samples)")
        ax.set_title("GPU Kernel Avg Duration (µs) — Nsight Systems")
        cbar = plt.colorbar(im, ax=ax)
        cbar.set_label("Avg duration (µs)")
        # annotate cells
        for ri in range(len(names)):
            for ci in range(len(loaded)):
                v = matrix[ri, ci]
                if not np.isnan(v):
                    ax.text(ci, ri, f"{v:.1f}", ha="center", va="center",
                            fontsize=7, color="black" if v < np.nanmax(matrix)*0.6 else "white")
        plt.tight_layout()
        out = os.path.join(args.out, "fig_m6_01_cufft_kernels_heatmap.png")
        plt.savefig(out, dpi=150)
        plt.close()
        print(f"  wrote {out}")

    # ── Fig 2: nsys avg vs CUDA-event p50 (FFT + H→D) ────────────────────────
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))

    for ax_idx, (metric, m5_col, mem_op_hint) in enumerate([
        ("cuFFT kernel", "fft_exec_us",       ""),
        ("H→D memcpy",  "transfer_latency_us", "HtoD"),
    ]):
        nsys_avgs = []
        event_p50s = []
        for bs in BUFFER_SIZES:
            # nsys GPU kernel or memop avg
            if metric.startswith("cuFFT"):
                v_ns = get_avg(kern_dfs.get(bs), "Name", "fft", "Avg (ns)")
                if np.isnan(v_ns):
                    # try total/instances
                    df = kern_dfs.get(bs)
                    if df is not None:
                        mask = df["Name"].str.contains("fft", case=False, na=False)
                        if mask.any():
                            sub = df[mask]
                            tot_col  = "Total Time (ns)" if "Total Time (ns)" in sub.columns else "Total Time"
                            inst_col = "Instances" if "Instances" in sub.columns else "Num Calls"
                            v_ns = (sub[tot_col] / sub[inst_col]).mean()
            else:
                v_ns = get_avg(mem_dfs.get(bs), "Operation", mem_op_hint, "Avg (ns)")

            nsys_avgs.append(ns_to_us(v_ns) if not np.isnan(v_ns) else np.nan)

            # CUDA-event p50 from M5 CSV
            df5 = m5_dfs.get(bs)
            if df5 is not None and m5_col in df5.columns:
                event_p50s.append(float(df5[m5_col].median()))
            else:
                event_p50s.append(np.nan)

        ax = axes[ax_idx]
        x = np.arange(len(BUFFER_SIZES))
        w = 0.35
        b1 = ax.bar(x - w/2, nsys_avgs,  w, label="Nsight avg",      color=PALETTE[0], alpha=0.85)
        b2 = ax.bar(x + w/2, event_p50s, w, label="CUDA-event p50",  color=PALETTE[1], alpha=0.85)
        ax.set_xticks(x)
        ax.set_xticklabels(BUF_LABELS)
        ax.set_ylabel("Duration (µs)")
        ax.set_title(f"{metric} — Nsight avg vs CUDA-event p50")
        ax.legend()
        ax.yaxis.set_minor_locator(mticker.AutoMinorLocator())
        ax.grid(axis="y", alpha=0.3)
        for bar_group in [b1, b2]:
            for bar in bar_group:
                h = bar.get_height()
                if not np.isnan(h) and h > 0:
                    ax.text(bar.get_x() + bar.get_width()/2, h + 0.3,
                            f"{h:.1f}", ha="center", va="bottom", fontsize=8)

    plt.suptitle("Nsight Systems vs CUDA Event Measurements", fontsize=13)
    plt.tight_layout()
    out = os.path.join(args.out, "fig_m6_02_cufft_avg_vs_events.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  wrote {out}")

    # ── Fig 3: top-5 kernels total time, grouped by buffer size ───────────────
    if loaded:
        # Find global top-5 kernel names by total time across all sizes
        name_totals: dict = {}
        for bs in loaded:
            df = kern_dfs[bs]
            if df is None:
                continue
            tot_col = "Total Time (ns)" if "Total Time (ns)" in df.columns else "Total Time"
            for _, row in df.iterrows():
                n = row["Name"]
                t = row.get(tot_col, 0)
                name_totals[n] = name_totals.get(n, 0) + t
        top5 = sorted(name_totals, key=name_totals.get, reverse=True)[:5]
        short5 = [re.sub(r'<[^>]*>', '', n)[:40] for n in top5]

        x  = np.arange(len(loaded))
        w  = 0.15
        fig, ax = plt.subplots(figsize=(12, 5))
        for ki, (kname, slabel) in enumerate(zip(top5, short5)):
            vals = []
            for bs in loaded:
                df = kern_dfs[bs]
                if df is None:
                    vals.append(0.0)
                    continue
                row = df[df["Name"] == kname]
                tot_col = "Total Time (ns)" if "Total Time (ns)" in df.columns else "Total Time"
                vals.append(ns_to_us(row[tot_col].values[0]) if not row.empty else 0.0)
            offset = (ki - len(top5)/2 + 0.5) * w
            bars = ax.bar(x + offset, vals, w, label=slabel,
                          color=PALETTE[ki % len(PALETTE)], alpha=0.85)

        ax.set_xticks(x)
        ax.set_xticklabels([f"{bs//1024}K" if bs >= 1024 else str(bs) for bs in loaded])
        ax.set_xlabel("Buffer size (samples)")
        ax.set_ylabel("Total execution time (µs)")
        ax.set_title("Top-5 GPU Kernels — Total Execution Time by Buffer Size")
        ax.legend(fontsize=7, loc="upper left")
        ax.grid(axis="y", alpha=0.3)
        plt.tight_layout()
        out = os.path.join(args.out, "fig_m6_03_top_kernels_bar.png")
        plt.savefig(out, dpi=150)
        plt.close()
        print(f"  wrote {out}")

    # ── Fig 4: memory op breakdown (H→D, D→H) by buffer size ─────────────────
    fig, ax = plt.subplots(figsize=(9, 5))
    op_keywords = {"HtoD": PALETTE[0], "DtoH": PALETTE[1], "DtoD": PALETTE[2]}
    x = np.arange(len(BUFFER_SIZES))
    w = 0.25
    offsets = [-w, 0, w]
    for oi, (kw, color) in enumerate(op_keywords.items()):
        vals = []
        for bs in BUFFER_SIZES:
            v_ns = get_avg(mem_dfs.get(bs), "Operation", kw, "Avg (ns)")
            vals.append(ns_to_us(v_ns) if not np.isnan(v_ns) else 0.0)
        if any(v > 0 for v in vals):
            bars = ax.bar(x + offsets[oi], vals, w, label=f"[{kw}]",
                          color=color, alpha=0.85)
            for bar in bars:
                h = bar.get_height()
                if h > 0:
                    ax.text(bar.get_x() + bar.get_width()/2, h + 0.2,
                            f"{h:.1f}", ha="center", va="bottom", fontsize=8)
    ax.set_xticks(x)
    ax.set_xticklabels(BUF_LABELS)
    ax.set_xlabel("Buffer size (samples)")
    ax.set_ylabel("Avg duration (µs)")
    ax.set_title("GPU MemOp Avg Duration by Direction & Buffer Size (Nsight)")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    plt.tight_layout()
    out = os.path.join(args.out, "fig_m6_04_memops_breakdown.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  wrote {out}")

    # ── Fig 5: CUDA API overhead (select APIs) ────────────────────────────────
    api_names = ["cudaMemcpy", "cudaLaunch", "cudaMalloc", "cudaFree",
                 "cuLaunchKernel", "cudaStreamSynchronize"]
    fig, axes2 = plt.subplots(1, 2, figsize=(14, 5))

    # Avg time per call
    ax = axes2[0]
    for bs_idx, bs in enumerate(BUFFER_SIZES):
        df = api_dfs.get(bs)
        if df is None:
            continue
        names_found, avgs = [], []
        avg_col = "Avg (ns)" if df is not None and "Avg (ns)" in df.columns else "Avg"
        for api in api_names:
            v = get_avg(df, "Name", api, avg_col)
            if not np.isnan(v):
                names_found.append(api)
                avgs.append(ns_to_us(v))
        if names_found:
            yp = np.arange(len(names_found))
            ax.barh(yp + bs_idx * 0.2 - 0.3, avgs, 0.2,
                    label=f"{bs//1024}K" if bs >= 1024 else str(bs),
                    color=PALETTE[bs_idx % len(PALETTE)], alpha=0.85)
            ax.set_yticks(yp)
            ax.set_yticklabels(names_found)
    ax.set_xlabel("Avg call duration (µs)")
    ax.set_title("CUDA API Avg Call Duration")
    ax.legend(title="buf size")
    ax.grid(axis="x", alpha=0.3)

    # Call count per buffer processed
    ax = axes2[1]
    for bs_idx, bs in enumerate(BUFFER_SIZES):
        df = api_dfs.get(bs)
        if df is None:
            continue
        names_found, counts = [], []
        # API summary uses 'Num Calls' column
        inst_col = "Num Calls" if df is not None and "Num Calls" in df.columns else "Instances"
        for api in api_names:
            if df is None:
                continue
            mask = df["Name"].str.contains(api, case=False, na=False, regex=False)
            if mask.any():
                names_found.append(api)
                counts.append(int(df.loc[mask, inst_col].values[0]))
        if names_found:
            yp = np.arange(len(names_found))
            ax.barh(yp + bs_idx * 0.2 - 0.3, counts, 0.2,
                    label=f"{bs//1024}K" if bs >= 1024 else str(bs),
                    color=PALETTE[bs_idx % len(PALETTE)], alpha=0.85)
            ax.set_yticks(yp)
            ax.set_yticklabels(names_found)
    ax.set_xlabel("Total call count (full run)")
    ax.set_title("CUDA API Call Counts")
    ax.legend(title="buf size")
    ax.grid(axis="x", alpha=0.3)

    plt.suptitle("CUDA API Overhead — Nsight Systems", fontsize=13)
    plt.tight_layout()
    out = os.path.join(args.out, "fig_m6_05_api_overhead.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  wrote {out}")

    # ── Fig 6: GPU time fraction pie per buffer size ──────────────────────────
    fig, axes3 = plt.subplots(1, len(BUFFER_SIZES), figsize=(14, 4))
    for ax, bs in zip(axes3, BUFFER_SIZES):
        kern_df = kern_dfs.get(bs)
        mem_df  = mem_dfs.get(bs)
        tot_kern_col = "Total Time (ns)" if kern_df is not None and "Total Time (ns)" in kern_df.columns else "Total Time"
        tot_mem_col  = "Total Time (ns)" if mem_df  is not None and "Total Time (ns)" in mem_df.columns  else "Total Time"
        total_kern = kern_df[tot_kern_col].sum() if kern_df is not None else 0
        total_mem  = mem_df[tot_mem_col].sum()   if mem_df  is not None else 0
        labels = ["GPU Kernels", "MemOps"]
        sizes  = [total_kern, total_mem]
        if sum(sizes) > 0:
            wedges, texts, autotexts = ax.pie(
                sizes, labels=labels, autopct="%1.1f%%",
                colors=[PALETTE[0], PALETTE[1]], startangle=90)
            for at in autotexts:
                at.set_fontsize(9)
        ax.set_title(f"{bs//1024}K samples" if bs >= 1024 else f"{bs} samples", fontsize=10)
    plt.suptitle("GPU Time Split: Kernels vs Memory Ops — Nsight Systems", fontsize=12)
    plt.tight_layout()
    out = os.path.join(args.out, "fig_m6_06_gpu_time_fraction.png")
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"  wrote {out}")

    print("\nDone.")


if __name__ == "__main__":
    main()
