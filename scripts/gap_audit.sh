#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# gap_audit.sh — is the sustained rate a rate, or is it one over a median?
#
# WHY THIS EXISTS
# extbuf_fft_server.cu:866 computes the headline rate as
#
#     mib_s = frame_bytes / gap_p50
#
# That is not bytes over elapsed time.  It is the reciprocal of the MEDIAN
# inter-arrival, and it equals the sustained rate only when the gap distribution
# has one mode.  If arrivals cluster (two land close together, then a long
# pause), the median sits inside the fast cluster while the mean sits where the
# wire actually is, and the reported rate can exceed the link.  The 1 MiB cells
# of the 2026-08-24 sweep reported 10792 to 13517 MiB/s on a 50 Gb/s link whose
# payload ceiling is 5960, which is 2.1x impossible, and the same cell flipped
# between roughly 76 us and roughly 176 us between reps with nothing changed.
# A knife-edge median over a bimodal distribution does exactly that.
#
# This script does not need a rebuild or a new run.  The per-message CSV already
# carries gap_us in field 10, so the honest rate can be recovered from data
# already taken:
#
#     span     = sum of all gaps = last arrival - first arrival
#     true     = n_gaps * frame_bytes / span
#
# Usage:
#   sh scripts/gap_audit.sh /tmp/tc_stream-inplace_262144_s4_1.srv.csv
#   for f in /tmp/tc_stream*_262144_*.srv.csv; do sh scripts/gap_audit.sh "$f"; done
# ─────────────────────────────────────────────────────────────────────────────

set -u
[ $# -ge 1 ] || { echo "usage: $0 <per-message-server-csv> [...]" >&2; exit 1; }

# 50 Gb/s: 6250 bytes/us signalling, so this many MiB/s of payload and no more.
LINK_MIB_S="${LINK_MIB_S:-5960}"

# CSV=1 emits one machine-readable row per file and skips the sort, so it is
# cheap enough to run over every cell of a sweep.  Used to produce
# data/honest_rates.csv, which is the committable form of this finding.
if [ "${CSV:-0}" = 1 ]; then
    echo "file,bytes,n_gaps,span_ms,gap_mean_us,mib_s_true"
    for F in "$@"; do
        [ -f "$F" ] || continue
        tail -n +2 "$F" | awk -F, -v f="$(basename "$F" .csv)" '
            $10 + 0 > 0 { s += $10; b = $3; ++k }
            END { if (k > 0 && s > 0)
                    printf "%s,%d,%d,%.1f,%.2f,%.0f\n",
                           f, b, k, s/1000.0, s/k,
                           k * b / s * 1e6 / (1024*1024) }'
    done
    exit 0
fi

for F in "$@"; do
    [ -f "$F" ] || { echo "$F: missing"; continue; }
    echo "=== $F"
    # Fields: 1 seq 2 slot 3 bytes 4 npts 5 e2e_us 6 fft_us 7 peak_hz
    #         8 expect_hz 9 ok 10 gap_us 11 gitsha
    tail -n +2 "$F" | awk -F, -v link="$LINK_MIB_S" '
        $10 != "" && $10 + 0 > 0 { g[n++] = $10 + 0; s += $10 + 0; b = $3 + 0 }
        END {
            if (n < 10) { print "  too few gaps"; exit }
            for (i = 0; i < n; i++) v[i] = g[i]
            # shell sort, plenty fast for a few hundred thousand rows
            for (gapx = int(n/2); gapx > 0; gapx = int(gapx/2))
                for (i = gapx; i < n; i++) {
                    t = v[i]; j = i
                    while (j >= gapx && v[j-gapx] > t) { v[j] = v[j-gapx]; j -= gapx }
                    v[j] = t
                }
            mean = s / n

            # The rate the server prints, and the rate the run actually ran at.
            med   = v[int(0.50 * (n-1))]
            r_med = b / med  * 1e6 / (1024*1024)
            r_true= b / mean * 1e6 / (1024*1024)

            printf "  gaps        : %d, span %.1f ms\n", n, s/1000.0
            printf "  gap us      : p1 %.1f  p10 %.1f  p25 %.1f  p50 %.1f  p75 %.1f  p90 %.1f  p99 %.1f\n", \
                   v[int(0.01*(n-1))], v[int(0.10*(n-1))], v[int(0.25*(n-1))], \
                   v[int(0.50*(n-1))], v[int(0.75*(n-1))], v[int(0.90*(n-1))], \
                   v[int(0.99*(n-1))]
            printf "  mean us     : %.2f   (median %.2f, mean/median %.2f)\n", mean, med, mean/med
            printf "  rate median : %8.0f MiB/s   <- what the server prints%s\n", \
                   r_med, (r_med > link*1.02 ? "   ABOVE LINK" : "")
            printf "  rate true   : %8.0f MiB/s   <- n*bytes/span%s\n", \
                   r_true, (r_true > link*1.02 ? "   ABOVE LINK" : "")

            # Bimodality, cheaply: what fraction of the mass sits below half the
            # mean, and what fraction above 1.5x it.  A unimodal cadence puts
            # almost nothing in either tail.  Clustering puts a lot in both.
            lo = 0; hi = 0
            for (i = 0; i < n; i++) {
                if (v[i] < 0.5 * mean) lo++
                else if (v[i] > 1.5 * mean) hi++
            }
            printf "  clustering  : %.1f%% of gaps < half the mean, %.1f%% > 1.5x the mean\n", \
                   100.0*lo/n, 100.0*hi/n
        }'
    echo
done
