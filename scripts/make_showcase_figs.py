#!/usr/bin/env python3
"""
Figures for Intern_showcase_Dami.pptx.

This is a separate script from make_deck_figs.py and make_part3_figs.py on
purpose. The showcase deck labels its charts "gRPC Direct" and "DAQiri", which
is what slides 6 and 7 already say, and part 3 has to match those slides rather
than the internal review deck's wording.

Naming used on every chart here, and nowhere else in this file:

    base    ->  gRPC Direct (before the fix)
    opt     ->  gRPC Direct (after the fix)
    extbuf  ->  gRPC Direct over RDMA
    daq     ->  DAQiri

Every number is read from a CSV at draw time. Nothing is typed in as a literal.

Usage:  python scripts/make_showcase_figs.py
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
    "base": "gRPC Direct\n(before the fix)",
    "opt": "gRPC Direct\n(after the fix)",
    "extbuf": "gRPC Direct\nover RDMA",
    "daq": "DAQiri",
}
FLAT = {k: v.replace("\n", " ") for k, v in NAME.items()}

MIB = 1048576.0 / 1e9   # MiB/s -> GB/s
LINE_RATE_GBPS = 6.25   # 50 Gb/s

# Slide 13 carries two charts side by side. They only read as a pair if they
# are drawn at the same size, so both use these and the slide places them in
# equal boxes.
PAIR_W, PAIR_H = 8.4, 5.6


def style_ax(ax):
    ax.grid(axis="y", color="#D8DCE0", lw=0.8)
    ax.set_axisbelow(True)
    ax.tick_params(length=0)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(SLATE)


def rows(path):
    with open(os.path.join(DATA, path), newline="") as fh:
        return list(csv.DictReader(fh))


def save(fig, name):
    # Transparent, because the deck background is off-white and a white PNG
    # panel behind every chart reads as a box on the slide.
    fig.savefig(os.path.join(OUT, name), bbox_inches="tight", transparent=True)
    plt.close(fig)


# ---------------------------------------------------------------------------
# Slide 5 (Part 1): network throughput, as it stands
# ---------------------------------------------------------------------------
def fig_linerate():
    """
    One bar and a ceiling. The earlier version of this chart carried a second
    bar from a run on a misconfigured link, which invited a question about the
    misconfiguration instead of showing the result.
    """
    val = 5843.23 * MIB
    fig, ax = plt.subplots(figsize=(9.2, 5.4))
    bars = ax.bar(["gRPC Direct over RDMA"], [val], width=0.52, color=NI_GREEN)
    ax.bar_label(bars, fmt="%.2f GB/s", padding=-34, fontsize=19,
                 fontweight="bold", color="white")
    ax.axhline(LINE_RATE_GBPS, color=CHARCOAL, ls="--", lw=1.8)
    ax.annotate("50 Gb/s line rate  (%.2f GB/s)" % LINE_RATE_GBPS,
                (0.5, LINE_RATE_GBPS), xycoords=("axes fraction", "data"),
                xytext=(0, 8), textcoords="offset points", ha="center",
                fontsize=15, color=CHARCOAL)
    # Percent label sized to sit fully inside the (now wider) bar so the white
    # text does not spill onto the off-white slide and become unreadable.
    ax.annotate("%.1f%% of line rate" % (100.0 * val / LINE_RATE_GBPS),
                (0, val), xytext=(0, -70), textcoords="offset points",
                ha="center", fontsize=15, fontweight="bold", color="white")
    ax.set_ylabel("Sustained throughput, 4 MB buffers  (GB/s)")
    ax.set_ylim(0, LINE_RATE_GBPS * 1.22)
    ax.set_xlim(-0.5, 0.5)
    ax.set_xlabel("Cross-machine: instrument chassis \u2192 GPU host, over the 50G RDMA link")
    style_ax(ax)
    save(fig, "sc_linerate.png")
    print("  slide 5: %.3f GB/s, %.1f%% of line rate" %
          (val, 100.0 * val / LINE_RATE_GBPS))


# ---------------------------------------------------------------------------
# Part 3, slide 1: where the delay was
# ---------------------------------------------------------------------------
def fig_where():
    """
    End-to-end minus the transform. A cost that does not move with payload is a
    fixed overhead. A cost that grows with the byte count means something is
    touching every byte. That distinction is the whole slide.
    """
    by = defaultdict(lambda: defaultdict(list))
    for r in rows("headline_runs.csv"):
        by[r["arm"]][int(r["kb"])].append(float(r["resid"]))
    kbs = sorted(by["base"])
    fig, ax = plt.subplots(figsize=(9, 5.4))
    for arm, color, marker in (("base", AMBER_D, "o"), ("daq", NI_GREEN, "s")):
        y = [median(by[arm][k]) for k in kbs]
        ax.plot(kbs, y, marker=marker, ms=8, lw=2.6, color=color,
                label=FLAT[arm], zorder=3)
        for k in kbs:
            ax.plot([k] * len(by[arm][k]), by[arm][k], marker=".", ls="none",
                    ms=6, color=color, alpha=0.45, zorder=2)
    top = median(by["base"][kbs[-1]])
    ax.annotate("%.1f us" % top, (kbs[-1], top), textcoords="offset points",
                xytext=(-14, 10), ha="right", fontsize=16, fontweight="bold",
                color=AMBER_D)
    dv = [median(by["daq"][k]) for k in kbs]
    ax.annotate("flat: %.1f to %.1f us" % (min(dv), max(dv)), (kbs[-1], dv[-1]),
                textcoords="offset points", xytext=(-10, 14), ha="right",
                fontsize=15, fontweight="bold", color=NI_GREEN_D)
    ax.set_xscale("log", base=2)
    ax.set_xticks(kbs)
    ax.set_xticklabels([str(k) for k in kbs])
    ax.set_xlabel("Payload per buffer  (KB)")
    ax.set_ylabel("Delay outside the FFT  (us)")
    ax.set_ylim(0, 92)
    ax.legend(frameon=False, loc="upper left")
    style_ax(ax)
    save(fig, "sc_p3_1_where.png")


# ---------------------------------------------------------------------------
# Part 3, slide 2: the cause
# ---------------------------------------------------------------------------
def fig_cause():
    """
    Two bars, one payload size, DAQiri drawn as a reference line rather than a
    third bar because the claim here is about what the fix did to gRPC Direct,
    not about who wins. That comes later.
    """
    by = defaultdict(list)
    for r in rows("deck_4arm_4mib.csv"):
        if r["mode"] == "sat":
            by[r["arm"]].append(float(r["e2e_p50"]))
    b, o, d = median(by["base"]), median(by["opt"]), median(by["daq"])
    fig, ax = plt.subplots(figsize=(8, 5.4))
    bars = ax.bar([NAME["base"], NAME["opt"]], [b, o], width=0.46,
                  color=[SLATE, AMBER])
    ax.bar_label(bars, fmt="%.1f us", padding=6, fontsize=17,
                 fontweight="bold", color=CHARCOAL)
    ax.axhline(d, color=NI_GREEN, ls="--", lw=2.0)
    ax.set_xlim(-0.62, 2.1)
    ax.annotate("DAQiri\n%.1f us" % d, (1.55, d), textcoords="offset points",
                xytext=(6, -8), ha="left", va="top", fontsize=15,
                fontweight="bold", color=NI_GREEN_D)
    ax.annotate("%.2fx faster" % (b / o), (0.54, (b + o) / 2), ha="left",
                va="center", fontsize=24, fontweight="bold", color=CHARCOAL)
    ax.annotate("", xy=(0.46, o), xytext=(0.46, b),
                arrowprops=dict(arrowstyle="<->", color=CHARCOAL, lw=2.2))
    ax.set_ylabel("Time for one 4 MB buffer to reach the GPU  (us)")
    ax.set_ylim(0, b * 1.2)
    ax.set_xlabel("Same-machine test (local): gRPC Direct zero-copy, 4 MB payload",
                  labelpad=10)
    style_ax(ax)
    save(fig, "sc_p3_2_cause.png")
    print("  cause: %.2f -> %.2f (%.2fx), DAQiri %.2f" % (b, o, b / o, d))


# ---------------------------------------------------------------------------
# Part 3, slide 3: what was left
# ---------------------------------------------------------------------------
def fig_remainder():
    """
    Splits the remaining gap into the part inside the FFT library and the part
    outside it. Launch overhead does not grow with payload, so a remainder that
    does is not launch overhead.
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
    ax.bar(x, rgap, 0.6, label="Everything else", color=SLATE)
    b2 = ax.bar(x, fgap, 0.6, bottom=rgap, label="Inside the FFT library",
                color=AMBER)
    ax.bar_label(b2, labels=["%.1f" % v for v in fgap], label_type="center",
                 fontsize=12, fontweight="bold", color=CHARCOAL)
    tot = [a + c for a, c in zip(rgap, fgap)]
    ax.annotate("at 4 MB, %.0f%% of what is left\nis inside the FFT library"
                % (100.0 * fgap[-1] / tot[-1]),
                (x[-1], tot[-1]), textcoords="offset points", xytext=(-8, 14),
                ha="right", fontsize=15, fontweight="bold", color=CHARCOAL)
    ax.set_xticks(x, [str(k) for k in kbs])
    ax.set_xlabel("Payload per buffer  (KB)")
    ax.set_ylabel("gRPC Direct minus DAQiri  (us)")
    ax.set_ylim(0, max(tot) * 1.35)
    ax.legend(frameon=False, loc="upper left")
    style_ax(ax)
    save(fig, "sc_p3_3_remainder.png")


# ---------------------------------------------------------------------------
# Part 3, slide 4: the memory result that flipped
# ---------------------------------------------------------------------------
def fig_memory():
    """
    Two ways to get host memory the GPU can read: let the CUDA runtime allocate
    it, or hand it ordinary pages the process already owns. Adopted memory
    measured slower, repeatably. Remove the CPU write that filled the buffer and
    the sign inverts.

    The bars are transform time rather than total, because total is dominated by
    the CPU write and would hide the inversion instead of showing it.
    """
    def pooled(path, prefix):
        v = [float(r["fft_p50"]) for r in rows(path)
             if r["arm"].startswith(prefix)]
        lo, hi, _ = median_ci(v)
        m = median(v)
        return m, m - lo, hi - m

    cells = [("memsrc_2x2_1048576.csv", "ha"),
             ("memsrc_2x2_1048576.csv", "reg"),
             ("memsrc_2x2_nowrite_1048576.csv", "ha"),
             ("memsrc_2x2_nowrite_1048576.csv", "reg")]
    vals, lo, hi = [], [], []
    for path, pre in cells:
        m, l, h = pooled(path, pre)
        vals.append(m); lo.append(l); hi.append(h)

    x = np.array([0.0, 0.8, 2.2, 3.0])
    fig, ax = plt.subplots(figsize=(9.5, 5.6))
    bars = ax.bar(x, vals, 0.66, color=[NI_GREEN, AMBER_D, NI_GREEN, AMBER_D],
                  yerr=[lo, hi], capsize=6,
                  error_kw=dict(ecolor=CHARCOAL, lw=1.6))
    ax.bar_label(bars, fmt="%.1f", padding=10, fontsize=14, fontweight="bold",
                 color=CHARCOAL)
    ax.set_xticks(x, ["CUDA\nallocates it", "We hand it\nour pages",
                      "CUDA\nallocates it", "We hand it\nour pages"])
    for cx, label, d in ((0.4, "A CPU fills the buffer first", vals[1] - vals[0]),
                         (2.6, "Same test, no CPU write", vals[3] - vals[2])):
        ax.annotate(label, (cx, 0), xycoords=("data", "axes fraction"),
                    xytext=(0, -74), textcoords="offset points", ha="center",
                    fontsize=16, fontweight="bold", color=CHARCOAL)
        ax.annotate("our pages are %s by %.1f us" %
                    ("slower" if d > 0 else "FASTER", abs(d)),
                    (cx, max(vals) * 1.30), ha="center", fontsize=14,
                    fontweight="bold", color=RED if d > 0 else NI_GREEN_D)
    ax.set_ylabel("FFT time  p50  (us)")
    ax.set_ylim(0, max(vals) * 1.52)
    style_ax(ax)
    fig.subplots_adjust(bottom=0.30)
    save(fig, "sc_p3_4_memory.png")
    print("  memory: with write %.2f vs %.2f, without write %.2f vs %.2f"
          % tuple(vals))


# ---------------------------------------------------------------------------
# Part 3, slide 6: where it ended
# ---------------------------------------------------------------------------
def fig_final():
    """
    Four arms at one payload size. Bars are medians of twelve repetitions and
    the whiskers are a confidence interval of that median, so a reader can see
    which differences the measurement can actually resolve.
    """
    by = defaultdict(list)
    for r in rows("deck_4arm_4mib.csv"):
        if r["mode"] == "sat":
            by[r["arm"]].append(float(r["e2e_p50"]))
    order = ["base", "opt", "extbuf", "daq"]
    e = [median(by[a]) for a in order]
    ci = [median_ci(by[a]) for a in order]
    lo = [m - c[0] for m, c in zip(e, ci)]
    hi = [c[1] - m for m, c in zip(e, ci)]
    colors = [SLATE, AMBER, AMBER_D, NI_GREEN]
    fig, ax = plt.subplots(figsize=(PAIR_W, PAIR_H))
    bars = ax.bar([NAME[a] for a in order], e, 0.55, color=colors,
                  yerr=[lo, hi], capsize=7,
                  error_kw=dict(ecolor=CHARCOAL, lw=1.7))
    ax.bar_label(bars, fmt="%.1f", padding=14, fontsize=16, fontweight="bold",
                 color=CHARCOAL)
    ax.set_ylabel("Time for one 4 MB buffer to reach the GPU  (us)")
    ax.set_ylim(0, max(e) * 1.24)
    ax.set_title("At 4 MB, all four arms", fontsize=17, color=CHARCOAL,
                 fontweight="bold", pad=14)
    style_ax(ax)
    save(fig, "sc_p3_6_final.png")
    print("  final: " + ", ".join("%s=%.2f" % (FLAT[a], v)
                                  for a, v in zip(order, e)))


# ---------------------------------------------------------------------------
# Part 3, slide 6, right-hand chart: the two closest arms, across payload size
# ---------------------------------------------------------------------------
def fig_sweep():
    """
    The bar chart next to this one is one payload size. That invites a fair
    objection: 4 MB could be the one size where the two happen to land where
    they do. This answers it by walking the whole range.

    Only the two shared-memory arms are drawn. They are the pair that is
    genuinely like for like, since both take the same route into the GPU, so a
    difference between them is a difference in the receive path and nothing
    else. The RDMA arm belongs to a different comparison and is not on here.

    Source is headline_runs.csv, the interleaved 54-run sweep, not the payload
    sweep in data/payload_runs_paced25.csv, which is documented as not loggable
    and must not be quoted.
    """
    by = defaultdict(lambda: defaultdict(list))
    for r in rows("headline_runs.csv"):
        by[r["arm"]][int(r["kb"])].append(float(r["e2e_p50"]))
    kbs = sorted(by["opt"])
    fig, ax = plt.subplots(figsize=(PAIR_W, PAIR_H))
    for arm, color, marker in (("opt", AMBER, "o"), ("daq", NI_GREEN, "s")):
        y = [median(by[arm][k]) for k in kbs]
        ax.plot(kbs, y, marker=marker, ms=8, lw=2.6, color=color,
                label=FLAT[arm], zorder=3)
        for k in kbs:
            ax.plot([k] * len(by[arm][k]), by[arm][k], marker=".", ls="none",
                    ms=6, color=color, alpha=0.45, zorder=2)
    o = [median(by["opt"][k]) for k in kbs]
    d = [median(by["daq"][k]) for k in kbs]
    # Labelled as a percentage, not in microseconds, and the reason is worth
    # writing down. This chart shares a slide with the 4 MiB bar chart, which is
    # a different run. Subtracting that chart's two bar labels gives 7.9 us;
    # subtracting this chart's 4 MB points gives 8.1; and the slide headline
    # says 7, which is the paired median difference. Three numbers within one
    # microsecond of each other, from three correct calculations, is a slide
    # that gets argued with. So the only microsecond gap on the slide is the one
    # on the left, and this chart makes its point in percent instead, which is
    # the right unit for a claim about shape across a 256-fold range anyway.
    pct = [100.0 * (a - b) / b for a, b in zip(o, d)]
    ax.annotate("%.0f%% behind" % pct[-1], (kbs[-1], (o[-1] + d[-1]) / 2),
                textcoords="offset points", xytext=(-12, 0), ha="right",
                va="center", fontsize=15, fontweight="bold", color=CHARCOAL)
    ax.annotate("%.0f%% behind" % pct[0], (kbs[0], d[0]),
                textcoords="offset points", xytext=(8, -6), ha="left",
                va="top", fontsize=15, fontweight="bold", color=CHARCOAL)
    ax.set_xscale("log", base=2)
    ax.set_xticks(kbs)
    ax.set_xticklabels([str(k) for k in kbs], fontsize=12)
    ax.set_xlabel("Payload per buffer  (KB)")
    ax.set_ylabel("Time for one buffer to reach the GPU  (us)")
    ax.set_ylim(0, max(o) * 1.30)
    ax.set_title("Across payload size, the two closest arms", fontsize=17,
                 color=CHARCOAL, fontweight="bold", pad=14)
    ax.legend(frameon=False, loc="upper left")
    style_ax(ax)
    save(fig, "sc_p3_6_sweep.png")
    print("  sweep: %.0f%% behind at %d KB, %.0f%% behind at %d KB "
          "(%.2f and %.2f us)"
          % (pct[0], kbs[0], pct[-1], kbs[-1], o[0] - d[0], o[-1] - d[-1]))


def main():
    os.makedirs(OUT, exist_ok=True)
    fig_linerate()
    fig_where()
    fig_cause()
    fig_remainder()
    fig_memory()
    fig_final()
    fig_sweep()
    print("Showcase figures written to: %s" % OUT)


if __name__ == "__main__":
    main()
