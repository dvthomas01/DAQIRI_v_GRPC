#!/usr/bin/env python3
"""
M9 — Pipeline B transport comparison (CORRECTED methodology).

Reads the matched-pace trial CSVs produced by matched_compare.sh:
  data/mc_<transport>_<BS>_<trial>.csv   (transport in {standard, shmem})
and the Pipeline A reference:
  data/daqiri_pipeline_<BS>.csv

Key change vs the earlier (superseded) fig_m7_* set:
  * The transport is characterised by WIRE latency (client send_timestamp ->
    server receive), NOT by H->D copy latency.  H->D is byte-identical code in
    both transports and is dominated by GPU DVFS (clock ramp) during paced
    idle gaps, so it is not a valid transport discriminator.
  * All transports are paced identically (matched feed rate) so the GPU clock
    state is the same for both — a fair comparison.

Generates:
  fig_m9_01_wire_latency.png      — WIRE latency p50/p95 std vs shmem (headline)
  fig_m9_02_wire_cdf.png          — WIRE latency CDF per buffer size
  fig_m9_03_delivery.png          — Delivery reliability (% received)
  fig_m9_04_throughput.png        — Throughput A / std / shmem
  fig_m9_05_latency_breakdown.png — Stacked wire + H->D + cuFFT (std vs shmem)
  fig_m9_06_e2e.png               — Server-side E2E p50 A / std / shmem
"""

import argparse
import glob
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

BUFFER_SIZES = [4096, 8192, 16384, 32768]
BUF_LABELS   = ["4K\n(16KB)", "8K\n(32KB)", "16K\n(64KB)", "32K\n(128KB)"]
N_EXPECTED   = 1000   # measured buffers per trial (matched_compare.sh N)

COLOR_A     = "#4C72B0"   # Pipeline A (DAQiri)
COLOR_STD   = "#DD8452"   # Pipeline B standard gRPC
COLOR_SHMEM = "#55A868"   # Pipeline B shmem
ALPHA       = 0.85

LABELS = {
    "a":     "Pipeline A (DAQiri)",
    "std":   "Pipeline B — standard gRPC",
    "shmem": "Pipeline B — shmem (gRPC Direct)",
}


def load_trials(data_dir, transport, bs):
    """Pool all trial CSVs for one (transport, size) into one DataFrame.
    Returns (pooled_df, n_trials)."""
    paths = sorted(glob.glob(os.path.join(data_dir, f"mc_{transport}_{bs}_*.csv")))
    frames = []
    for p in paths:
        try:
            df = pd.read_csv(p)
        except Exception:
            continue
        if not df.empty:
            frames.append(df)
    if not frames:
        return None, 0
    return pd.concat(frames, ignore_index=True), len(frames)


def load_a(data_dir, bs):
    p = os.path.join(data_dir, f"daqiri_pipeline_{bs}.csv")
    if not os.path.exists(p):
        return None
    try:
        df = pd.read_csv(p)
    except Exception:
        return None
    return df if not df.empty else None


def wire_series(df):
    """Positive wire-latency values only (drop CLOCK_REALTIME jumps / missing)."""
    if df is None or "wire_latency_us" not in df.columns:
        return None
    s = df["wire_latency_us"]
    s = s[s > 0]
    return s if len(s) else None


def pct(series, p):
    return float(np.percentile(series, p))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data")
    ap.add_argument("--out",  default="data/figures")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    std   = {bs: load_trials(args.data, "standard", bs) for bs in BUFFER_SIZES}
    shm   = {bs: load_trials(args.data, "shmem",    bs) for bs in BUFFER_SIZES}
    a_ref = {bs: load_a(args.data, bs)                   for bs in BUFFER_SIZES}

    print("standard:", [bs for bs in BUFFER_SIZES if std[bs][0] is not None])
    print("shmem   :", [bs for bs in BUFFER_SIZES if shm[bs][0] is not None])
    print("A (ref) :", [bs for bs in BUFFER_SIZES if a_ref[bs] is not None])

    x = np.arange(len(BUFFER_SIZES))
    w = 0.38

    # ── Fig 1: WIRE latency p50 / p95 (headline) ─────────────────────────────
    fig, axes = plt.subplots(1, 2, figsize=(13, 5.2))
    handles = None
    for ax, pv in zip(axes, [50, 95]):
        vs, vsh = [], []
        for bs in BUFFER_SIZES:
            ss = wire_series(std[bs][0]); sh = wire_series(shm[bs][0])
            vs.append(pct(ss, pv) if ss is not None else 0)
            vsh.append(pct(sh, pv) if sh is not None else 0)
        b1 = ax.bar(x - w / 2, vs,  w, label=LABELS["std"],   color=COLOR_STD,   alpha=ALPHA)
        b2 = ax.bar(x + w / 2, vsh, w, label=LABELS["shmem"], color=COLOR_SHMEM, alpha=ALPHA)
        ax.set_xticks(x); ax.set_xticklabels(BUF_LABELS)
        ax.set_ylabel("Wire latency (µs)")
        ax.set_title(f"Transport (wire) latency — p{pv}")
        ax.set_ylim(0, max(vs + vsh) * 1.15)
        ax.grid(axis="y", alpha=0.3)
        _annotate(ax, list(b1) + list(b2))
        handles = [b1, b2]
    fig.legend(handles, [LABELS["std"], LABELS["shmem"]],
               loc="lower center", ncol=2, fontsize=9, frameon=False,
               bbox_to_anchor=(0.5, 0.90))
    plt.suptitle("Pipeline B transport latency: client send → server receive "
                 "(matched pace, lower = better)", fontsize=12, y=0.99)
    plt.tight_layout(rect=(0, 0, 1, 0.86))
    _save(plt, args.out, "fig_m9_01_wire_latency.png")

    # ── Fig 2: WIRE latency CDF per buffer size ──────────────────────────────
    fig, axcds = plt.subplots(1, len(BUFFER_SIZES), figsize=(15, 4))
    for ax, bs in zip(axcds, BUFFER_SIZES):
        ss = wire_series(std[bs][0]); sh = wire_series(shm[bs][0])
        if ss is not None:
            sv = np.sort(ss.values)
            ax.plot(sv, np.linspace(0, 1, len(sv)), color=COLOR_STD, lw=1.6, label="standard")
        if sh is not None:
            sv = np.sort(sh.values)
            ax.plot(sv, np.linspace(0, 1, len(sv)), color=COLOR_SHMEM, lw=1.6, label="shmem")
        ax.set_title(f"{bs} samples ({bs*4//1024}KB)", fontsize=9)
        ax.set_xlabel("Wire latency (µs)", fontsize=8)
        ax.set_xscale("log")
        if ax is axcds[0]:
            ax.set_ylabel("CDF", fontsize=8)
        ax.grid(alpha=0.3); ax.legend(fontsize=7)
    plt.suptitle("Transport (wire) latency CDF — standard gRPC vs shmem", fontsize=12)
    plt.tight_layout()
    _save(plt, args.out, "fig_m9_02_wire_cdf.png")

    # ── Fig 3: Delivery reliability (% of expected buffers received) ─────────
    fig, ax = plt.subplots(figsize=(10, 5))
    ds, dsh = [], []
    for bs in BUFFER_SIZES:
        _, nts = std[bs]
        _, nsh = shm[bs]
        rs = (len(std[bs][0]) / nts) if nts else 0
        rh = (len(shm[bs][0]) / nsh) if nsh else 0
        ds.append(100.0 * rs / N_EXPECTED)
        dsh.append(100.0 * rh / N_EXPECTED)
    b1 = ax.bar(x - w / 2, ds,  w, label=LABELS["std"],   color=COLOR_STD,   alpha=ALPHA)
    b2 = ax.bar(x + w / 2, dsh, w, label=LABELS["shmem"], color=COLOR_SHMEM, alpha=ALPHA)
    ax.set_xticks(x); ax.set_xticklabels(BUF_LABELS)
    ax.set_ylabel("Delivered (% of sent)"); ax.set_ylim(0, 105)
    ax.axhline(100, color="grey", ls="--", lw=0.8)
    ax.set_title("Delivery reliability — gRPC backpressure (100%) vs "
                 "shmem lossy ring")
    ax.legend(fontsize=8); ax.grid(axis="y", alpha=0.3)
    _annotate(ax, list(b1) + list(b2), fmt="{:.1f}%")
    plt.tight_layout()
    _save(plt, args.out, "fig_m9_03_delivery.png")

    # ── Fig 4: Throughput A / std / shmem ────────────────────────────────────
    fig, ax = plt.subplots(figsize=(10, 5))
    ww = 0.25
    ta, ts, tsh = [], [], []
    for bs in BUFFER_SIZES:
        da = a_ref[bs]
        ta.append(da["mb_per_sec"].median() if da is not None and "mb_per_sec" in da else 0)
        ts.append(std[bs][0]["mb_per_sec"].median() if std[bs][0] is not None else 0)
        tsh.append(shm[bs][0]["mb_per_sec"].median() if shm[bs][0] is not None else 0)
    b1 = ax.bar(x - ww, ta,  ww, label=LABELS["a"],     color=COLOR_A,     alpha=ALPHA)
    b2 = ax.bar(x,      ts,  ww, label=LABELS["std"],   color=COLOR_STD,   alpha=ALPHA)
    b3 = ax.bar(x + ww, tsh, ww, label=LABELS["shmem"], color=COLOR_SHMEM, alpha=ALPHA)
    ax.set_xticks(x); ax.set_xticklabels(BUF_LABELS)
    ax.set_xlabel("Buffer size"); ax.set_ylabel("Throughput (MB/s)")
    ax.set_title("Throughput — DAQiri vs standard gRPC vs shmem")
    ax.legend(fontsize=8); ax.grid(axis="y", alpha=0.3)
    _annotate(ax, list(b1) + list(b2) + list(b3))
    plt.tight_layout()
    _save(plt, args.out, "fig_m9_04_throughput.png")

    # ── Fig 5: Stacked latency breakdown (wire + H->D + cuFFT) ───────────────
    fig, ax = plt.subplots(figsize=(11, 6))
    ww = 0.38
    comp = {}
    for tag, src in [("std", std), ("shmem", shm)]:
        wire_v, h2d_v, fft_v = [], [], []
        for bs in BUFFER_SIZES:
            df = src[bs][0]
            ws = wire_series(df)
            wire_v.append(pct(ws, 50) if ws is not None else 0)
            h2d_v.append(pct(df["transfer_latency_us"], 50) if df is not None else 0)
            fft_v.append(pct(df["fft_exec_us"], 50) if df is not None else 0)
        comp[tag] = (wire_v, h2d_v, fft_v)
    for i, (tag, off, hatch) in enumerate([("std", -ww / 2, None),
                                           ("shmem", ww / 2, "//")]):
        wire_v, h2d_v, fft_v = comp[tag]
        ax.bar(x + off, wire_v, ww, color=COLOR_STD if tag == "std" else COLOR_SHMEM,
               alpha=0.9, hatch=hatch, label=f"{tag}: wire (transport)")
        ax.bar(x + off, h2d_v, ww, bottom=wire_v, color="#8172B3", alpha=0.9,
               hatch=hatch, label=f"{tag}: H→D copy")
        ax.bar(x + off, fft_v, ww,
               bottom=np.array(wire_v) + np.array(h2d_v),
               color="#C44E52", alpha=0.9, hatch=hatch, label=f"{tag}: cuFFT")
    ax.set_xticks(x); ax.set_xticklabels(BUF_LABELS)
    ax.set_xlabel("Buffer size"); ax.set_ylabel("p50 latency (µs)")
    ax.set_title("Per-stage latency breakdown (p50): wire + H→D + cuFFT\n"
                 "left bar = standard gRPC, right (hatched) = shmem")
    ax.legend(fontsize=7, ncol=2); ax.grid(axis="y", alpha=0.3)
    plt.tight_layout()
    _save(plt, args.out, "fig_m9_05_latency_breakdown.png")

    # ── Fig 6: Server-side E2E p50 (A / std / shmem) ─────────────────────────
    fig, ax = plt.subplots(figsize=(10, 5))
    ww = 0.25
    ea, es, esh = [], [], []
    for bs in BUFFER_SIZES:
        da = a_ref[bs]
        ea.append(pct(da["e2e_latency_us"], 50) if da is not None else 0)
        es.append(pct(std[bs][0]["e2e_latency_us"], 50) if std[bs][0] is not None else 0)
        esh.append(pct(shm[bs][0]["e2e_latency_us"], 50) if shm[bs][0] is not None else 0)
    b1 = ax.bar(x - ww, ea,  ww, label=LABELS["a"],     color=COLOR_A,     alpha=ALPHA)
    b2 = ax.bar(x,      es,  ww, label=LABELS["std"],   color=COLOR_STD,   alpha=ALPHA)
    b3 = ax.bar(x + ww, esh, ww, label=LABELS["shmem"], color=COLOR_SHMEM, alpha=ALPHA)
    ax.set_xticks(x); ax.set_xticklabels(BUF_LABELS)
    ax.set_xlabel("Buffer size"); ax.set_ylabel("Server E2E p50 (µs)")
    ax.set_title("Server-side E2E (receive → FFT done) — GPU processing, "
                 "transport-independent")
    ax.legend(fontsize=8); ax.grid(axis="y", alpha=0.3)
    _annotate(ax, list(b1) + list(b2) + list(b3))
    plt.tight_layout()
    _save(plt, args.out, "fig_m9_06_e2e.png")

    print("\nDone.")


# ── helpers ───────────────────────────────────────────────────────────────────

def _annotate(ax, bars, fmt="{:.1f}"):
    for bar in bars:
        h = bar.get_height()
        if h > 0:
            ax.text(bar.get_x() + bar.get_width() / 2, h * 1.01,
                    fmt.format(h), ha="center", va="bottom", fontsize=6.5)


def _save(plt_mod, out_dir, name):
    path = os.path.join(out_dir, name)
    plt_mod.savefig(path, dpi=150)
    plt_mod.close()
    print(f"  wrote {path}")


if __name__ == "__main__":
    main()
