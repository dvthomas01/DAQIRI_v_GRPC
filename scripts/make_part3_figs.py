#!/usr/bin/env python3
"""
Figures for part 3 of the deck: where the gap was, what caused it, what was
left, what the memory experiment found, and where it ended.

Every number here is read from a CSV in data/ at draw time. Nothing is typed in
as a literal, because part 1 of this deck already demonstrated what happens when
a chart carries hardcoded numbers whose source has gone missing.

Arm names follow the plain-language mapping used everywhere in the deck:

    base    ->  gRPC-Direct (before)
    opt     ->  gRPC-Direct (optimized)
    extbuf  ->  gRPC-Direct over RDMA
    daq     ->  DAQiri

Slide 5 is a data-path diagram rather than a chart and is not produced here.

Usage:  python scripts/make_part3_figs.py
"""

import csv
import os
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deck_4arm_table import median, median_ci  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
OUT = os.path.join(ROOT, "presentation", "figs")

NI_GREEN = "#03B585"
NI_GREEN_D = "#028C66"
CHARCOAL = "#1B1B1B"
SLATE = "#5A6470"
AMBER = "#F5A623"
AMBER_D = "#C77F11"
RED = "#C44E52"

plt.rcParams.update({
    "font.family": ["Segoe UI", "DejaVu Sans", "Arial"],
    "font.size": 15,
    "savefig.dpi": 200,
    "axes.spines.top": False,
    "axes.spines.right": False,
})

NAME = {
    "base": "gRPC-Direct (before)",
    "opt": "gRPC-Direct (optimized)",
    "extbuf": "gRPC-Direct over RDMA",
    "daq": "DAQiri",
}


def style_ax(ax):
    ax.grid(axis="y", color="#D8DCE0", lw=0.8)
    ax.set_axisbelow(True)
    ax.tick_params(length=0)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(SLATE)


def rows(path):
    with open(os.path.join(DATA, path), newline="") as fh:
        return list(csv.DictReader(fh))


# ----------------------------------------------------------------------------
# Slide 1: where the gap was
# ----------------------------------------------------------------------------
def fig_s1_residual_vs_payload():
    """
    Residual is end-to-end minus the transform. A cost that does not depend on
    payload is a fixed overhead. A cost that grows with the byte count means
    something is touching every byte. That distinction is the whole slide, and
    it is visible without knowing the cause yet.
    """
    by = defaultdict(lambda: defaultdict(list))
    for r in rows("headline_runs.csv"):
        by[r["arm"]][int(r["kb"])].append(float(r["resid"]))
    kbs = sorted(by["base"])
    fig, ax = plt.subplots(figsize=(9, 5.4))
    for arm, color, marker in (("base", AMBER_D, "o"), ("daq", NI_GREEN, "s")):
        y = [median(by[arm][k]) for k in kbs]
        ax.plot(kbs, y, marker=marker, ms=8, lw=2.6, color=color,
                label=NAME[arm], zorder=3)
        # Both individual reps as faint dots, so the rep count is visible in
        # the chart rather than only in a footnote.
        for k in kbs:
            ax.plot([k] * len(by[arm][k]), by[arm][k], marker=".", ls="none",
                    ms=6, color=color, alpha=0.45, zorder=2)
    ax.annotate("%.1f us" % median(by["base"][kbs[-1]]),
                (kbs[-1], median(by["base"][kbs[-1]])),
                textcoords="offset points", xytext=(-14, 10), ha="right",
                fontsize=15, fontweight="bold", color=AMBER_D)
    dvals = [median(by["daq"][k]) for k in kbs]
    ax.annotate("flat, %.2f to %.2f us" % (min(dvals), max(dvals)),
                (kbs[-1], dvals[-1]),
                textcoords="offset points", xytext=(-10, 12), ha="right",
                fontsize=14, fontweight="bold", color=NI_GREEN_D)
    ax.set_xscale("log", base=2)
    ax.set_xticks(kbs)
    ax.set_xticklabels([str(k) for k in kbs])
    ax.set_xlabel("Payload per buffer  (KB)")
    ax.set_ylabel("Residual: end-to-end minus transform  (us)")
    ax.set_ylim(0, 92)
    ax.legend(frameon=False, loc="upper left")
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p3_s1_residual_vs_payload.png"))
    plt.close(fig)


# ----------------------------------------------------------------------------
# Slide 2: the root cause
# ----------------------------------------------------------------------------
def fig_s2_root_cause():
    """
    One payload size, 4 MB, three bars. DAQiri is drawn as a reference line
    rather than a fourth bar because the claim on this slide is about what the
    fix did to gRPC-Direct, not about who wins.
    """
    by = defaultdict(list)
    for r in rows("headline_runs.csv"):
        if int(r["kb"]) == 4096:
            by[r["arm"]].append(float(r["e2e_p50"]))
    b, o, d = (median(by["base"]), median(by["opt"]), median(by["daq"]))
    fig, ax = plt.subplots(figsize=(8, 5.4))
    bars = ax.bar([NAME["base"], NAME["opt"]], [b, o],
                  color=[AMBER_D, NI_GREEN], width=0.5)
    ax.bar_label(bars, fmt="%.2f us", padding=4, fontsize=15,
                 fontweight="bold", color=CHARCOAL)
    ax.axhline(d, color=SLATE, ls="--", lw=1.6)
    ax.set_xlim(-0.6, 2.05)
    ax.annotate("DAQiri\n%.2f us" % d, (1.5, d), textcoords="offset points",
                xytext=(6, -6), ha="left", va="top", fontsize=14,
                fontweight="bold", color=SLATE)
    ax.annotate("%.2fx" % (b / o), (0.5, (b + o) / 2),
                ha="center", fontsize=30, fontweight="bold", color=NI_GREEN_D)
    ax.annotate("", xy=(0.5, o), xytext=(0.5, b),
                arrowprops=dict(arrowstyle="<->", color=NI_GREEN_D, lw=2.2))
    ax.set_ylabel("End-to-end latency  p50  (us)")
    ax.set_ylim(0, b * 1.22)
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p3_s2_root_cause.png"))
    plt.close(fig)


# ----------------------------------------------------------------------------
# Slide 3: what was left, and where it lives
# ----------------------------------------------------------------------------
def fig_s3_where_it_lives():
    """
    After the fix, gRPC-Direct is still behind DAQiri. This splits that
    remainder into the part inside cuFFT and the part outside it. Launch
    overhead does not depend on payload, so a remainder that grows with the
    byte count is not launch overhead, which is what points at the buffer.
    """
    fft = defaultdict(lambda: defaultdict(list))
    res = defaultdict(lambda: defaultdict(list))
    for r in rows("headline_runs.csv"):
        fft[r["arm"]][int(r["kb"])].append(float(r["fft_p50"]))
        res[r["arm"]][int(r["kb"])].append(float(r["resid"]))
    kbs = sorted(fft["opt"])
    fgap = [median(fft["opt"][k]) - median(fft["daq"][k]) for k in kbs]
    rgap = [median(res["opt"][k]) - median(res["daq"][k]) for k in kbs]
    x = np.arange(len(kbs))
    fig, ax = plt.subplots(figsize=(9.5, 5.4))
    b1 = ax.bar(x, rgap, 0.6, label="Outside cuFFT (residual)", color=SLATE)
    b2 = ax.bar(x, fgap, 0.6, bottom=rgap, label="Inside cuFFT", color=AMBER)
    ax.bar_label(b2, labels=["%.1f" % v for v in fgap], label_type="center",
                 fontsize=12, fontweight="bold", color=CHARCOAL)
    tot = [a + c for a, c in zip(rgap, fgap)]
    share = 100.0 * fgap[-1] / tot[-1]
    ax.annotate("at 4 MB, %.0f%% of what is\nleft is inside cuFFT" % share,
                (x[-1], tot[-1]), textcoords="offset points", xytext=(-8, 14),
                ha="right", fontsize=14, fontweight="bold", color=CHARCOAL)
    ax.set_xticks(x, [str(k) for k in kbs])
    ax.set_xlabel("Payload per buffer  (KB)")
    ax.set_ylabel("gRPC-Direct (optimized) minus DAQiri  (us)")
    ax.set_ylim(0, max(tot) * 1.35)
    ax.legend(frameon=False, loc="upper left")
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p3_s3_where_it_lives.png"))
    plt.close(fig)


# ----------------------------------------------------------------------------
# Slide 4: the memory finding
# ----------------------------------------------------------------------------
def fig_s4_memory():
    """
    Two ways to get host memory the GPU can reach:

      allocated  cudaHostAlloc, the runtime picks the pages
      adopted    ordinary pages the process already owns, handed to
                 cudaHostRegister after the fact

    Adopted memory measured slower, repeatably. Then the CPU write that filled
    the buffer was removed, and the sign inverted. Both measurements are
    correct about what they measured. The error available here was to carry one
    of them into a configuration it had not measured, which is exactly the
    configuration that matters: in the real receiver a NIC writes the buffer
    and the CPU never touches it.

    The bars are transform time, not total, because total is dominated by the
    CPU write and would hide the inversion rather than show it.
    """
    def pooled(path, prefix):
        v = [float(r["fft_p50"]) for r in rows(path)
             if r["arm"].startswith(prefix)]
        lo, hi, _ = median_ci(v)
        m = median(v)
        return m, m - lo, hi - m, len(v)

    cells = [
        ("memsrc_2x2_1048576.csv", "ha"),
        ("memsrc_2x2_1048576.csv", "reg"),
        ("memsrc_2x2_nowrite_1048576.csv", "ha"),
        ("memsrc_2x2_nowrite_1048576.csv", "reg"),
    ]
    vals, lo, hi, ns = [], [], [], []
    for path, pre in cells:
        m, l, h, n = pooled(path, pre)
        vals.append(m); lo.append(l); hi.append(h); ns.append(n)

    x = np.array([0.0, 0.8, 2.2, 3.0])
    colors = [NI_GREEN, AMBER_D, NI_GREEN, AMBER_D]
    fig, ax = plt.subplots(figsize=(9.5, 5.6))
    bars = ax.bar(x, vals, 0.66, color=colors,
                  yerr=[lo, hi], capsize=6,
                  error_kw=dict(ecolor=CHARCOAL, lw=1.6))
    ax.bar_label(bars, fmt="%.1f", padding=10, fontsize=14,
                 fontweight="bold", color=CHARCOAL)
    ax.set_xticks(x, ["Allocated", "Adopted", "Allocated", "Adopted"])
    for cx, label, d in ((0.4, "CPU writes the buffer first", vals[1] - vals[0]),
                         (2.6, "Same test, CPU write removed", vals[3] - vals[2])):
        ax.annotate(label, (cx, 0), xycoords=("data", "axes fraction"),
                    xytext=(0, -46), textcoords="offset points", ha="center",
                    fontsize=15, fontweight="bold", color=CHARCOAL)
        ax.annotate("adopted %s by %.1f us" %
                    ("slower" if d > 0 else "faster", abs(d)),
                    (cx, max(vals) * 1.14), ha="center", fontsize=14,
                    color=RED if d > 0 else NI_GREEN_D, fontweight="bold")
    ax.set_ylabel("Transform time  p50  (us)")
    ax.set_ylim(0, max(vals) * 1.3)
    style_ax(ax)
    fig.subplots_adjust(bottom=0.24)
    fig.savefig(os.path.join(OUT, "p3_s4_memory.png"), bbox_inches="tight")
    plt.close(fig)
    print("  slide 4 cells (fft p50, pooled over alignment): " +
          ", ".join("%s/%s=%.2f n=%d" % (c[1], c[0].split("_")[-1], v, n)
                    for c, v, n in zip(cells, vals, ns)))


# ----------------------------------------------------------------------------
# Slide 6: where it ended
# ----------------------------------------------------------------------------
def fig_s6_four_arm(mode):
    """
    Four arms at one payload size with error bars. The bars are medians of
    twelve reps and the whiskers are a distribution-free confidence interval of
    that median, so a reader can see directly whether two arms are separated by
    more than the measurement can resolve.
    """
    path = os.path.join(DATA, "deck_4arm_4mib.csv")
    if not os.path.exists(path):
        print("  slide 6 skipped: %s not present yet" % path)
        return
    by = defaultdict(list)
    pace = None
    for r in rows("deck_4arm_4mib.csv"):
        if r["mode"] != mode:
            continue
        pace = float(r["pace_us"])
        by[r["arm"]].append((float(r["e2e_p50"]), float(r["fft_p50"])))
    order = [a for a in ("base", "opt", "extbuf", "daq") if by.get(a)]
    if len(order) < 4:
        print("  slide 6 (%s) skipped: only %d arms present" % (mode, len(order)))
        return
    e = [median([v[0] for v in by[a]]) for a in order]
    ci = [median_ci([v[0] for v in by[a]]) for a in order]
    lo = [m - c[0] for m, c in zip(e, ci)]
    hi = [c[1] - m for m, c in zip(e, ci)]
    nrep = len(by[order[0]])
    colors = {"base": AMBER_D, "opt": AMBER, "extbuf": NI_GREEN_D,
              "daq": NI_GREEN}
    fig, ax = plt.subplots(figsize=(9.5, 5.6))
    bars = ax.bar([NAME[a].replace(" (", "\n(").replace(" over", "\nover")
                   for a in order], e, 0.55,
                  color=[colors[a] for a in order],
                  yerr=[lo, hi], capsize=7,
                  error_kw=dict(ecolor=CHARCOAL, lw=1.6))
    ax.bar_label(bars, fmt="%.1f", padding=12, fontsize=15,
                 fontweight="bold", color=CHARCOAL)
    ax.set_ylabel("End-to-end latency  p50  (us)")
    ax.set_ylim(0, max(e) * 1.26)
    ax.set_title("4 MiB payload, %d reps, %.0f us pacing" % (nrep, pace),
                 fontsize=14, color=SLATE, pad=14)
    style_ax(ax)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "p3_s6_four_arm_%s.png" % mode))
    plt.close(fig)
    print("  slide 6 (%s): " % mode +
          ", ".join("%s=%.2f" % (NAME[a], v) for a, v in zip(order, e)))


def main():
    os.makedirs(OUT, exist_ok=True)
    fig_s1_residual_vs_payload()
    fig_s2_root_cause()
    fig_s3_where_it_lives()
    fig_s4_memory()
    fig_s6_four_arm("sat")
    fig_s6_four_arm("unsat")
    print("Part 3 figures written to: %s" % OUT)


if __name__ == "__main__":
    main()
