#!/usr/bin/env python3
"""
plot_spectrum.py — Plot the FFT magnitude spectrum from a spectrum CSV.

The spectrum CSV is produced by fft_validate immediately after a run:
  data/spectrum_N<N>.csv   (columns: bin_index, frequency_hz, magnitude)

Usage:
  # On Spark (headless):
  python3 scripts/plot_spectrum.py data/spectrum_N16384.csv

  # Zoom to 0–5 kHz and annotate top-5 peaks:
  python3 scripts/plot_spectrum.py data/spectrum_N16384.csv --max-freq 5000

  # Custom output path:
  python3 scripts/plot_spectrum.py data/spectrum_N16384.csv --out data/figures/spectrum.png
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")   # headless — no display required
import matplotlib.pyplot as plt

plt.rcParams.update({
    "figure.dpi":        150,
    "axes.spines.top":   False,
    "axes.spines.right": False,
    "font.size":         11,
    "axes.titlesize":    13,
    "axes.labelsize":    11,
})


def plot_spectrum(csv_path: str, max_freq: float | None, n_peaks: int, out_path: str) -> None:
    df = pd.read_csv(csv_path)

    if max_freq is not None:
        df = df[df["frequency_hz"] <= max_freq]

    # Identify top-k peaks (exclude DC bin 0)
    df_no_dc = df[df["bin_index"] > 0]
    top = df_no_dc.nlargest(n_peaks, "magnitude")

    fig, ax = plt.subplots(figsize=(11, 4.5))

    ax.plot(
        df["frequency_hz"] / 1e3,   # Hz → kHz
        df["magnitude"],
        color="#76b900", linewidth=0.9, alpha=0.9, label="Magnitude spectrum",
    )

    # Shade under curve
    ax.fill_between(
        df["frequency_hz"] / 1e3,
        df["magnitude"],
        alpha=0.15, color="#76b900",
    )

    # Annotate top peaks
    for _, row in top.iterrows():
        freq_khz = row["frequency_hz"] / 1e3
        mag      = row["magnitude"]
        label    = f'{row["frequency_hz"]:.0f} Hz\n({mag:.3f})'
        ax.annotate(
            label,
            xy=(freq_khz, mag),
            xytext=(0, 14),
            textcoords="offset points",
            ha="center", va="bottom",
            fontsize=8, color="#222222",
            arrowprops=dict(arrowstyle="-|>", color="#888888",
                            lw=0.7, mutation_scale=8),
        )

    ax.set_xlabel("Frequency (kHz)")
    ax.set_ylabel("Normalised Magnitude")
    zoom_note = f" (0 – {max_freq/1e3:.1f} kHz)" if max_freq else ""
    ax.set_title(f"FFT Magnitude Spectrum{zoom_note}")
    ax.set_ylim(bottom=0)
    ax.legend(loc="upper right", fontsize=9)

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Plot FFT magnitude spectrum from CSV.")
    parser.add_argument("csv",
                        help="Spectrum CSV produced by fft_validate "
                             "(columns: bin_index, frequency_hz, magnitude)")
    parser.add_argument("--max-freq", type=float, default=None,
                        help="Zoom: only display up to this frequency in Hz (e.g. 5000)")
    parser.add_argument("--peaks", type=int, default=5,
                        help="Number of top peaks to annotate (default: 5)")
    parser.add_argument("--out", default=None,
                        help="Output PNG path (default: <csv_stem>.png in data/figures/)")
    args = parser.parse_args()

    if not Path(args.csv).is_file():
        print(f"ERROR: file not found: {args.csv}", file=sys.stderr)
        sys.exit(1)

    out = args.out or str(Path("data/figures") / (Path(args.csv).stem + ".png"))
    plot_spectrum(args.csv, args.max_freq, args.peaks, out)


if __name__ == "__main__":
    main()
