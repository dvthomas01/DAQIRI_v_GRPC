#!/usr/bin/env python3
"""Generate NI-branded figures for the two presentation decks.

Phase 1 (grpc-direct transport benchmark) numbers are taken from the project
README headline table. Phase 2 (DAQiri vs gRPC-Direct GPU FFT pipeline) numbers
are aggregated live from the airtight A/B trial CSVs in data/.

Outputs PNGs to presentation/figs/ and prints the aggregated Phase-2 table so the
exact numbers can be quoted on the slides.
"""
import glob
import os
import statistics

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# ----------------------------------------------------------------------------
# NI palette
# ----------------------------------------------------------------------------
NI_GREEN = "#03B585"
NI_GREEN_D = "#028C66"   # darker green (copy variant)
CHARCOAL = "#1B1B1B"
SLATE = "#5A6470"
OFFWHITE = "#F7F8F9"
AMBER = "#F5A623"
AMBER_D = "#C77F11"      # darker amber (copy variant)
LIGHTGRN = "#E0F5EE"
RED = "#C44E52"

plt.rcParams.update({
    "font.family": "Segoe UI, DejaVu Sans, Arial",
    "font.size": 15,
    "axes.edgecolor": SLATE,
    "axes.labelcolor": CHARCOAL,
    "axes.titlecolor": CHARCOAL,
    "xtick.color": CHARCOAL,
    "ytick.color": CHARCOAL,
    "axes.grid": True,
    "grid.color": "#D9DEE3",
    "grid.linewidth": 0.8,
    "figure.facecolor": "white",
    "axes.facecolor": "white",
    "savefig.dpi": 200,
    "savefig.bbox": "tight",
})

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATA = os.path.join(ROOT, "data")
OUT = os.path.join(ROOT, "presentation", "figs")
os.makedirs(OUT, exist_ok=True)

SIZES = [4096, 8192, 16384, 32768]
BYTE_LABELS = ["16 KB", "32 KB", "64 KB", "128 KB"]

PREFIX = {
    ("daqiri", "copy"): "ab_daqiri_copy",
    ("daqiri", "zerocopy"): "ab_daqiri_zerocopy",
    ("grpc", "copy"): "ab_grpc_copy",
    ("grpc", "zerocopy"): "ab_grpc_zerocopy",
}


def p50(xs):
    s = sorted(v for v in xs if v == v)
    return s[len(s) // 2] if s else float("nan")


def med(xs):
    xs = [x for x in xs if x == x]
    return statistics.median(xs) if xs else float("nan")


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
        fft=p50(df["fft_exec_us"].tolist()),
        mbps=p50(df["mb_per_sec"].tolist()),
    )


def aggregate():
    summary = {}
    for key, prefix in PREFIX.items():
        for bs in SIZES:
            paths = sorted(glob.glob(os.path.join(DATA, f"{prefix}_{bs}_*.csv")))
            st = [s for s in (trial_stats(p) for p in paths) if s]
            if not st:
                continue
            summary[(key, bs)] = dict(
                trials=len(st),
                deliv=med([s["rows"] for s in st]),
                transfer=med([s["transfer"] for s in st]),
                e2e=med([s["e2e"] for s in st]),
                fft=med([s["fft"] for s in st]),
                mbps=med([s["mbps"] for s in st]),
            )
    return summary


def style_ax(ax):
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.set_axisbelow(True)


# ----------------------------------------------------------------------------
# PHASE 2 figures
# ----------------------------------------------------------------------------
def fig_p2_zerocopy_latency(summary):
    d = [summary[(("daqiri", "zerocopy"), b)]["e2e"] for b in SIZES]
    g = [summary[(("grpc", "zerocopy"), b)]["e2e"] for b in SIZES]
    x = np.arange(len(SIZES))
    w = 0.38
    fig, ax = plt.subplots(figsize=(9, 5))
    b1 = ax.bar(x - w / 2, d, w, label="DAQiri, zero-copy", color=NI_GREEN)
    b2 = ax.bar(x + w / 2, g, w, label="gRPC-Direct, zero-copy", color=AMBER)
    for i in range(len(SIZES)):
        adv = (g[i] - d[i]) / d[i] * 100
        ax.annotate(f"{adv:+.0f}%", (x[i] + w / 2, g[i]),
                    textcoords="offset points", xytext=(0, 20),
                    ha="center", fontsize=13, fontweight="bold", color=SLATE)
    ax.bar_label(b1, fmt="%.1f", padding=2, fontsize=11, color=CHARCOAL)
    ax.bar_label(b2, fmt="%.1f", padding=2, fontsize=11, color=CHARCOAL)
    ax.set_xticks(x, BYTE_LABELS)
    ax.set_xlabel("Payload per buffer")
    ax.set_ylabel("End-to-end latency  p50  (µs)")
    ax.set_ylim(0, max(g) * 1.32)
    ax.legend(frameon=False, loc="upper left")
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p2_zerocopy_latency.png"))
    plt.close(fig)


def fig_p2_copy_penalty(summary):
    # gRPC copy vs zero-copy — the CPU copy that zero-copy removes
    gc = [summary[(("grpc", "copy"), b)]["e2e"] for b in SIZES]
    gz = [summary[(("grpc", "zerocopy"), b)]["e2e"] for b in SIZES]
    x = np.arange(len(SIZES))
    w = 0.38
    fig, ax = plt.subplots(figsize=(9, 5))
    b1 = ax.bar(x - w / 2, gc, w, label="gRPC-Direct, with CPU copy", color=AMBER_D)
    b2 = ax.bar(x + w / 2, gz, w, label="gRPC-Direct, zero-copy", color=NI_GREEN)
    ax.bar_label(b1, fmt="%.0f", padding=2, fontsize=11, color=CHARCOAL)
    ax.bar_label(b2, fmt="%.0f", padding=2, fontsize=11, color=CHARCOAL)
    ax.set_xticks(x, BYTE_LABELS)
    ax.set_xlabel("Payload per buffer")
    ax.set_ylabel("End-to-end latency  p50  (µs)")
    ax.set_ylim(0, max(gc) * 1.18)
    ax.legend(frameon=False, loc="lower center", bbox_to_anchor=(0.5, 1.01),
              ncol=2, fontsize=12)
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p2_copy_penalty.png"))
    plt.close(fig)


def fig_p2_headtohead(summary):
    order = [("daqiri", "copy"), ("grpc", "copy"),
             ("daqiri", "zerocopy"), ("grpc", "zerocopy")]
    labels = ["DAQiri, with CPU copy", "gRPC-Direct, with CPU copy",
              "DAQiri, zero-copy", "gRPC-Direct, zero-copy"]
    colors = [NI_GREEN_D, AMBER_D, NI_GREEN, AMBER]
    x = np.arange(len(SIZES))
    w = 0.2
    fig, ax = plt.subplots(figsize=(10, 5.4))
    for i, key in enumerate(order):
        vals = [summary[(key, b)]["e2e"] for b in SIZES]
        ax.bar(x + (i - 1.5) * w, vals, w, label=labels[i], color=colors[i])
    ax.set_xticks(x, BYTE_LABELS)
    ax.set_xlabel("Payload per buffer")
    ax.set_ylabel("End-to-end latency  p50  (µs)")
    ax.legend(frameon=False, ncol=4, loc="lower center",
              bbox_to_anchor=(0.5, 1.01), fontsize=12)
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p2_headtohead.png"))
    plt.close(fig)


def fig_p2_delivery(summary):
    dc = [summary[(("daqiri", "copy"), b)]["deliv"] for b in SIZES]
    dz = [summary[(("daqiri", "zerocopy"), b)]["deliv"] for b in SIZES]
    gz = [summary[(("grpc", "zerocopy"), b)]["deliv"] for b in SIZES]
    x = np.arange(len(SIZES))
    w = 0.26
    fig, ax = plt.subplots(figsize=(9, 5.2))
    ax.bar(x - w, dc, w, label="DAQiri, with CPU copy", color=NI_GREEN_D)
    ax.bar(x, dz, w, label="DAQiri, zero-copy", color=NI_GREEN)
    ax.bar(x + w, gz, w, label="gRPC-Direct, zero-copy", color=AMBER)
    ax.axhline(1000, color=SLATE, ls="--", lw=1.2)
    ax.annotate("1000 expected", (0.5, 1000), textcoords="offset points",
                xytext=(0, 6), ha="center", fontsize=11, color=SLATE)
    # highlight the 128 KB cliff, pointing at the short DAQiri copy bar
    ax.annotate("drop at 128 KB", (3 - w, dc[3]),
                textcoords="offset points", xytext=(-4, 120),
                ha="center", fontsize=13, fontweight="bold", color=RED,
                arrowprops=dict(arrowstyle="->", color=RED, lw=1.6))
    ax.set_xticks(x, BYTE_LABELS)
    ax.set_xlabel("Payload per buffer")
    ax.set_ylabel("Buffers delivered  (of 1000)")
    ax.set_ylim(0, 1120)
    ax.legend(frameon=False, ncol=3, loc="lower center",
              bbox_to_anchor=(0.5, 1.01), fontsize=12)
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p2_delivery.png"))
    plt.close(fig)


# ----------------------------------------------------------------------------
# PHASE 1 figures (from README headline table)
# ----------------------------------------------------------------------------
def fig_p1_latency():
    # Same-machine (localhost) only, so every bar shares ONE test condition and
    # ONE baseline. The cross-machine grpc-direct RDMA bar (36.8 us, PXI->Spark
    # over the 50G wire) was removed: it is not comparable to the localhost
    # shmem / TCP-LL bars. Pairing cross-machine RDMA next to localhost TCP-LL
    # made RDMA look slower than TCP-LL, which is a test-condition artifact, not
    # a transport result. Baseline is the real localhost standard-gRPC Echo p50
    # (929 us), so 929/21.2 = 44x and 929/3.3 = 281x are both against the same
    # baseline. The cross-machine RDMA / DAQiri story lives on the Part-1
    # network slides, not here.
    names = ["Standard gRPC", "Fast TCP", "Shared Memory"]
    vals = [929.0, 21.2, 3.3]
    speed = ["baseline", "44×", "281×"]
    colors = [SLATE, NI_GREEN_D, NI_GREEN]
    fig, ax = plt.subplots(figsize=(9, 5))
    bars = ax.bar(names, vals, color=colors, width=0.62)
    ax.set_yscale("log")
    ax.set_ylabel("Echo round-trip  p50  (µs, log scale)")
    for b, v, s in zip(bars, vals, speed):
        ax.annotate(f"{v:.1f} µs\n{s}", (b.get_x() + b.get_width() / 2, v),
                    textcoords="offset points", xytext=(0, 6),
                    ha="center", fontsize=12, fontweight="bold", color=CHARCOAL)
    ax.set_ylim(1, 3000)
    # same-host physical floor (native echo): shared memory sits right on it.
    # Line only; it is named in the slide side-text and footnote to avoid
    # colliding with the bars at this y-level.
    ax.axhline(2.78, color=SLATE, ls=":", lw=1.5, zorder=1)
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p1_latency.png"))
    plt.close(fig)


def fig_p1_throughput():
    names = ["Standard gRPC\n(copy)", "grpc-direct shmem\n(zero-copy)"]
    vals = [1.78, 23.59]
    colors = [SLATE, NI_GREEN]
    fig, ax = plt.subplots(figsize=(7.5, 5))
    bars = ax.bar(names, vals, color=colors, width=0.55)
    ax.bar_label(bars, fmt="%.2f GB/s", padding=4, fontsize=13,
                 fontweight="bold", color=CHARCOAL)
    ax.set_ylabel("Streaming throughput  (GB/s)")
    ax.set_ylim(0, 27)
    ax.annotate("3.9×", (1, 23.59), textcoords="offset points", xytext=(40, -30),
                fontsize=20, fontweight="bold", color=NI_GREEN)
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p1_throughput.png"))
    plt.close(fig)


def fig_p1_rdma_linerate():
    # This chart used to show two equal bars at 5.775 GB/s, one for gRPC-Direct
    # RDMA and one for DAQiri RDMA, captioned as a tie at the fabric limit.
    # That claim is withdrawn. Both numbers were the same fabric pinned at a
    # misconfigured RoCE MTU of 1024, so the pair measured the misconfiguration
    # rather than either transport. Correcting the MTU to 4096 moved the same
    # link to 5843.23 MiB/s while the 2-byte control did not move, which is what
    # attributes the change to the MTU. There is no DAQiri measurement at the
    # corrected MTU, so the second bar is removed rather than relabelled: a
    # caption cannot undo a bar chart.
    #
    # Source: handoff.md, gate 3. ib_write_bw, PXI writing into the Spark.
    MIB = 1048576.0 / 1e9
    names = ["Measured at MTU 1024\n(misconfigured)",
             "Measured at MTU 4096\n(corrected)"]
    vals = [5518.37 * MIB, 5843.23 * MIB]
    colors = [SLATE, NI_GREEN]
    line_rate = 6.25  # 50 Gb/s
    fig, ax = plt.subplots(figsize=(7.5, 5))
    bars = ax.bar(names, vals, color=colors, width=0.5)
    ax.axhline(line_rate, color=CHARCOAL, ls="--", lw=1.4)
    ax.annotate("50G line rate (6.25 GB/s)", (0, line_rate),
                textcoords="offset points", xytext=(0, 6), fontsize=12,
                color=CHARCOAL)
    ax.bar_label(bars, fmt="%.3f GB/s", padding=-30, fontsize=14,
                 fontweight="bold", color="white")
    ax.annotate("%.1f%% of line rate" % (100.0 * vals[1] / line_rate),
                (1, vals[1]), textcoords="offset points", xytext=(0, -62),
                ha="center", fontsize=14, fontweight="bold", color="white")
    ax.set_ylabel("RDMA write throughput, 4 MB  (GB/s)")
    ax.set_ylim(0, 7)
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p1_rdma_linerate.png"))
    plt.close(fig)


def main():
    summary = aggregate()
    # print table for quoting exact numbers on slides
    print(f"{'payload':>10} {'pipeline/mode':>22} {'trials':>6} {'deliv':>6} "
          f"{'xfer':>7} {'e2e':>7} {'fft':>7} {'mbps':>9}")
    order = [("daqiri", "copy"), ("grpc", "copy"),
             ("daqiri", "zerocopy"), ("grpc", "zerocopy")]
    for bs, lbl in zip(SIZES, BYTE_LABELS):
        for key in order:
            s = summary.get((key, bs))
            if not s:
                continue
            name = f"{key[0]}/{key[1]}"
            print(f"{lbl:>10} {name:>22} {s['trials']:>6} {s['deliv']:>6.0f} "
                  f"{s['transfer']:>7.2f} {s['e2e']:>7.2f} {s['fft']:>7.2f} {s['mbps']:>9.1f}")

    fig_p2_zerocopy_latency(summary)
    fig_p2_copy_penalty(summary)
    fig_p2_headtohead(summary)
    fig_p2_delivery(summary)
    fig_p1_latency()
    fig_p1_throughput()
    fig_p1_rdma_linerate()
    print("\nFigures written to:", OUT)
    for f in sorted(os.listdir(OUT)):
        print("  ", f)


if __name__ == "__main__":
    main()
