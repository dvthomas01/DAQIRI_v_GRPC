#!/usr/bin/env python3
"""Settle the opt-vs-DAQiri disagreement at 4 MiB.

Reads data/settle_runs.csv. Reports each arm's distribution across reps, then
the paired within-rep differences that the rotation was designed to produce.
Pairing matters here: the two sweeps that disagreed both used 3 reps and both
reported medians, and the medians disagreed because the underlying quantity is
not unimodal. Paired differences with a sign test say something a median of
three cannot.

Usage: settle_table.py [csv]
"""
import sys
from collections import defaultdict
from math import comb

ARM_NAME = {
    'daqpre': 'DAQiri pre-change build',
    'daqoff': 'DAQiri current, timers off',
    'daqon':  'DAQiri current, timers on',
    'opt':    'gRPC optimized',
}


def median(v):
    s = sorted(v)
    n = len(s)
    if n == 0:
        return float('nan')
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def sign_p(pos, neg):
    """Two-sided exact binomial p at q=0.5, ties excluded."""
    n = pos + neg
    if n == 0:
        return 1.0
    k = max(pos, neg)
    tail = sum(comb(n, i) for i in range(k, n + 1))
    return min(1.0, 2.0 * tail / (2 ** n))


def load(path):
    rows = []
    with open(path) as f:
        hdr = f.readline().strip().split(',')
        for line in f:
            p = line.strip().split(',')
            if len(p) != len(hdr):
                continue
            r = dict(zip(hdr, p))
            try:
                r['rep'] = int(r['rep'])
                r['pos'] = int(r['pos'])
                r['e2e'] = float(r['e2e_p50'])
                r['fft'] = float(r['fft_p50'])
                r['n'] = int(r['n'])
                r['mhz'] = int(r['sm_mhz'])
            except (ValueError, KeyError):
                continue
            rows.append(r)
    return rows


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'data/settle_runs.csv'
    rows = load(path)
    if not rows:
        print('no usable rows in ' + path)
        return

    by_arm = defaultdict(dict)
    for r in rows:
        by_arm[r['arm']][r['rep']] = r
    arms = [a for a in ('daqpre', 'daqoff', 'daqon', 'opt') if a in by_arm]
    reps = sorted({r['rep'] for r in rows})

    print('=' * 78)
    print('PER REP, 4 MiB, cuFFT p50 us   (the quantity the two tables disagreed on)')
    print('=' * 78)
    print('rep   ' + ''.join('%-14s' % a for a in arms))
    for rp in reps:
        cells = []
        for a in arms:
            r = by_arm[a].get(rp)
            cells.append('%-14s' % ('%.2f' % r['fft'] if r else '--'))
        print('%-6d' % rp + ''.join(cells))
    print('-' * 78)
    for label, key in (('median', 'fft'),):
        print('%-6s' % label + ''.join(
            '%-14s' % ('%.2f' % median([r[key] for r in by_arm[a].values()]))
            for a in arms))
    print('%-6s' % 'min' + ''.join(
        '%-14s' % ('%.2f' % min(r['fft'] for r in by_arm[a].values())) for a in arms))
    print('%-6s' % 'max' + ''.join(
        '%-14s' % ('%.2f' % max(r['fft'] for r in by_arm[a].values())) for a in arms))
    print('%-6s' % 'e2e' + ''.join(
        '%-14s' % ('%.2f' % median([r['e2e'] for r in by_arm[a].values()]))
        for a in arms))
    print('%-6s' % 'MHz' + ''.join(
        '%-14s' % ('%d' % median([r['mhz'] for r in by_arm[a].values()]))
        for a in arms))
    print('%-6s' % 'msgs' + ''.join(
        '%-14s' % ('%d' % median([r['n'] for r in by_arm[a].values()]))
        for a in arms))

    def paired(a, b, key):
        """b minus a, within rep. Positive means b is slower."""
        d = []
        for rp in reps:
            ra, rb = by_arm[a].get(rp), by_arm[b].get(rp)
            if ra and rb:
                d.append((rp, rb[key] - ra[key]))
        return d

    comparisons = [
        ('daqpre', 'daqoff', 'does the source change matter'),
        ('daqoff', 'daqon',  'does taking the timestamps cost anything'),
        ('daqoff', 'opt',    'THE QUESTION: is opt slower than DAQiri'),
        ('daqon',  'opt',    'same, against the instrumented build'),
    ]

    for key, unit in (('fft', 'cuFFT'), ('e2e', 'e2e')):
        print()
        print('=' * 78)
        print('PAIRED WITHIN-REP DIFFERENCES, %s us  (positive = second arm slower)' % unit)
        print('=' * 78)
        for a, b, why in comparisons:
            if a not in by_arm or b not in by_arm:
                continue
            d = paired(a, b, key)
            if not d:
                continue
            vals = [x for _, x in d]
            pos = sum(1 for x in vals if x > 0)
            neg = sum(1 for x in vals if x < 0)
            print('%s minus %s' % (b, a))
            print('   %s' % why)
            print('   per rep : ' + ' '.join('%+.2f' % x for x in vals))
            print('   median %+.2f   range %+.2f to %+.2f   %d of %d positive   p=%.4f'
                  % (median(vals), min(vals), max(vals), pos, pos + neg, sign_p(pos, neg)))
            srt = sorted(vals)
            gaps = [(srt[i + 1] - srt[i], i) for i in range(len(srt) - 1)]
            if gaps:
                g, i = max(gaps)
                span = srt[-1] - srt[0]
                if span > 0 and g > 0.45 * span and len(srt) >= 6:
                    print('   NOTE bimodal: %d values near %.2f, %d near %.2f, gap %.2f'
                          % (i + 1, median(srt[:i + 1]), len(srt) - i - 1,
                             median(srt[i + 1:]), g))
            print()

    # Position effect. Arm order rotates, so any drift across a rep shows up
    # here rather than being charged to a fixed arm. Each cell is expressed
    # against its own rep's mean, which removes rep-to-rep level shifts.
    print('=' * 78)
    print('POSITION EFFECT, cuFFT us against the rep mean  (the reason order is rotated)')
    print('=' * 78)
    by_pos = defaultdict(list)
    for rp in reps:
        cells = [r for r in rows if r['rep'] == rp]
        if len(cells) < 2:
            continue
        m = sum(c['fft'] for c in cells) / len(cells)
        for c in cells:
            by_pos[c['pos']].append(c['fft'] - m)
    for p in sorted(by_pos):
        v = by_pos[p]
        print('  position %d : median %+.2f   n=%d   range %+.2f to %+.2f'
              % (p, median(v), len(v), min(v), max(v)))
    if len(by_pos) > 1:
        meds = [median(by_pos[p]) for p in sorted(by_pos)]
        print('  spread across positions: %.2f us' % (max(meds) - min(meds)))


main()
