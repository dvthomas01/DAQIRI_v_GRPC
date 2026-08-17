#!/usr/bin/env python3
"""Clock-fair comparison table: gRPC-Direct vs DAQiri RoCE, one sweep window.

Both sweeps ran back to back on 2026-08-17 with identical parameters
(N=200 W=50 pace=400us).  That matters more than usual here: GPU clocks cannot
be locked on this box, and the earlier cross-run numbers (DAQiri 63.7 vs gRPC
75.9 at 4 MB) overstated the gap.

Residual = e2e - fft_exec.  It is the part of the latency that is NOT the
transform, i.e. everything the transport and the completion path add.
"""
import csv
import os

SIZES = [4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576]
DATA = "data"


def load(path):
    if not os.path.exists(path):
        return None
    e2e, fft = [], []
    with open(path) as fh:
        for r in csv.DictReader(fh):
            e2e.append(float(r["e2e_latency_us"]))
            fft.append(float(r["fft_exec_us"]))
    if not e2e:
        return None
    return e2e, fft


def pct(v, q):
    s = sorted(v)
    return s[min(len(s) - 1, int(q * len(s)))]


hdr = "%-7s %-9s %-9s %-9s %-8s %-9s %-9s %-9s %-8s"
print(hdr % ("KB", "gr_base", "gr_new", "daq", "gap", "gr_fft", "daq_fft",
             "gr_resid", "daq_res"))
print("-" * 86)

rows = []
for s in SIZES:
    kb = s * 4 // 1024
    base = load("%s/grpc_zcbase_%d.csv" % (DATA, s))
    new = load("%s/grpc_zerocopy_%d.csv" % (DATA, s))
    daq = load("%s/daqiri_roce_zerocopy_%d.csv" % (DATA, s))
    if not (new and daq):
        continue
    b50 = pct(base[0], .50) if base else float("nan")
    n50, nf = pct(new[0], .50), pct(new[1], .50)
    d50, df = pct(daq[0], .50), pct(daq[1], .50)
    print(hdr % (kb, "%.2f" % b50, "%.2f" % n50, "%.2f" % d50,
                 "%+.2f" % (n50 - d50), "%.2f" % nf, "%.2f" % df,
                 "%.2f" % (n50 - nf), "%.2f" % (d50 - df)))
    rows.append((kb, b50, n50, d50, nf, df))

print()
print("speedup from the alignment fix, and how much of the gap is left:")
print("%-7s %-9s %-9s %-9s" % ("KB", "speedup", "gap_before", "gap_after"))
for kb, b50, n50, d50, nf, df in rows:
    print("%-7s %-9s %-9s %-9s" % (kb, "%.2fx" % (b50 / n50),
                                   "%+.1f" % (b50 - d50), "%+.1f" % (n50 - d50)))
