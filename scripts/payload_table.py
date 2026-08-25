#!/usr/bin/env python3
"""Build the payload-size comparison from a payload_sweep.sh run.

Reads one or both passes and prints, per payload size and per arm, the three
terms the sweep measures plus their sum.

  fill        sender-side, getting one message's samples into the buffer the
              transport reads from. The signal is synthesised once at startup in
              all three arms, so this is the whole of their per-message data
              creation.
  transport   sender's clock immediately before handing off, to the receiver's
              clock the instant the message is in hand. Reported as a median
              with a p05 and p95 beside it, because in two of the three arms the
              distribution is not unimodal and the median alone would mislead.
  e2e         receiver-side, buffer in hand to post-FFT. The same window every
              earlier table in this project reported.
  fft         the cuFFT kernels, from CUDA events. Inside e2e, not added to it.

  total       fill + transport + e2e, which is the pipeline the user asked for.

Two guards on interpretation, both applied automatically:

  saturated   p95 over p05 above 3 means the arm was queueing, so its transport
              is a backlog measurement and its total is a throughput figure
              wearing a latency's clothes.
  short       fewer rows than the other arms in the same cell means messages
              went missing, which the gRPC shared-memory ring does silently
              when the sender outruns the handler.

Repetition. The settle sweep measured the single-cell standard deviation at
4.4 us at 4 MiB, so a difference under about 5 us between two arms at that size
is not resolved by six reps and is reported as a tie.
"""
import sys
import math
from collections import defaultdict

ARM_NAME = {
    'opt':    'gRPC optimized',
    'extbuf': 'gRPC over RDMA',
    'daq':    'DAQiri',
    'base':   'gRPC baseline',
}
ARM_ORDER = ['opt', 'extbuf', 'daq', 'base']

# Below this many microseconds two arms at 4 MiB are a tie, per the settle
# sweep's 4.4 us single-cell standard deviation.
TIE_US = 5.0


def median(xs):
    s = sorted(xs)
    n = len(s)
    if n == 0:
        return None
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def sign_p(pos, neg):
    """Two-sided exact binomial on the number of positive differences."""
    n = pos + neg
    if n == 0:
        return 1.0
    k = min(pos, neg)
    tail = sum(math.comb(n, i) for i in range(0, k + 1))
    return min(1.0, 2.0 * tail / (2 ** n))


def load(path):
    rows = []
    with open(path) as fh:
        header = fh.readline().rstrip('\n').split(',')
        idx = {name: i for i, name in enumerate(header)}
        for line in fh:
            line = line.rstrip('\n')
            if not line:
                continue
            f = line.split(',')
            if len(f) != len(header):
                continue

            def num(name):
                try:
                    return float(f[idx[name]])
                except (ValueError, KeyError):
                    return None

            rows.append({
                'arm':   f[idx['arm']],
                'size':  int(f[idx['size']]),
                'rep':   int(f[idx['rep']]),
                'pos':   int(f[idx['pos']]),
                'fill':  num('fill_p50'),
                't05':   num('transport_p05'),
                't50':   num('transport_p50'),
                't95':   num('transport_p95'),
                'e2e':   num('e2e_p50'),
                'fft':   num('fft_p50'),
                'n':     num('n'),
                'mhz':   num('sm_mhz'),
                'pace':  num('pace_us'),
            })
    return rows


def kib(size):
    b = size * 4
    if b >= 1 << 20:
        return '%d MiB' % (b >> 20)
    return '%d KiB' % (b >> 10)


def cell(rows, arm, size, key):
    vals = [r[key] for r in rows
            if r['arm'] == arm and r['size'] == size and r[key] is not None]
    return median(vals), vals


def spread(vals):
    if not vals:
        return ''
    return '%.1f-%.1f' % (min(vals), max(vals))


def report(path, label):
    rows = load(path)
    if not rows:
        print('no rows in %s' % path)
        return

    sizes = sorted({r['size'] for r in rows})
    arms = [a for a in ARM_ORDER if any(r['arm'] == a for r in rows)]
    reps = len({r['rep'] for r in rows})

    print()
    print('=' * 100)
    print('%s   (%s, %d reps, arms rotated through every position)'
          % (label, path, reps))
    print('=' * 100)

    for size in sizes:
        pace = median([r['pace'] for r in rows if r['size'] == size]) or 0
        print()
        print('--- %s payload (%d samples), sender paced %d us apart ---'
              % (kib(size), size, pace))
        print('%-17s %9s %11s %19s %10s %10s %12s  %s'
              % ('arm', 'fill', 'transport', '(p05..p95)', 'e2e',
                 'of which', 'TOTAL', 'notes'))
        print('%-17s %9s %11s %19s %10s %10s %12s'
              % ('', 'us', 'us', 'us', 'us', 'fft us', 'us'))

        counts = {}
        totals = {}
        for arm in arms:
            fill, fv = cell(rows, arm, size, 'fill')
            t50, _ = cell(rows, arm, size, 't50')
            t05, _ = cell(rows, arm, size, 't05')
            t95, _ = cell(rows, arm, size, 't95')
            e2e, ev = cell(rows, arm, size, 'e2e')
            fft, _ = cell(rows, arm, size, 'fft')
            nmed, _ = cell(rows, arm, size, 'n')
            counts[arm] = nmed

            notes = []
            if t05 and t95 and t05 > 0 and t95 / t05 > 3.0:
                notes.append('SATURATED: transport is queueing, not latency')
            if all(x is not None for x in (fill, t50, e2e)):
                totals[arm] = fill + t50 + e2e
                tot = '%.1f' % totals[arm]
            else:
                tot = 'n/a'

            print('%-17s %9s %11s %19s %10s %10s %12s  %s'
                  % (ARM_NAME[arm],
                     '%.2f' % fill if fill is not None else 'n/a',
                     '%.1f' % t50 if t50 is not None else 'n/a',
                     '%.1f .. %.1f' % (t05, t95)
                     if t05 is not None and t95 is not None else '',
                     '%.2f' % e2e if e2e is not None else 'n/a',
                     '%.2f' % fft if fft is not None else 'n/a',
                     tot,
                     '; '.join(notes)))

        best = max((v for v in counts.values() if v), default=0)
        for arm in arms:
            if counts.get(arm) and best and counts[arm] < best * 0.98:
                print('    NOTE: %s recorded %d of %d messages. The '
                      'shared-memory ring drops silently when the sender '
                      'outruns the handler, so this cell is a survivor sample.'
                      % (ARM_NAME[arm], counts[arm], best))

        # Who wins each term, and by how much against the noise floor.
        for key, name in (('fft', 'transform'), ('e2e', 'receiver window')):
            vals = {}
            for arm in arms:
                m, _ = cell(rows, arm, size, key)
                if m is not None:
                    vals[arm] = m
            if len(vals) < 2:
                continue
            order = sorted(vals.items(), key=lambda kv: kv[1])
            gap = order[1][1] - order[0][1]
            verdict = ('%s, by %.2f us' % (ARM_NAME[order[0][0]], gap)
                       if gap >= TIE_US or size < 262144
                       else 'tie (%.2f us gap, under the %.0f us noise floor)'
                            % (gap, TIE_US))
            print('    fastest %-16s %s' % (name + ':', verdict))

        if totals:
            order = sorted(totals.items(), key=lambda kv: kv[1])
            print('    fastest %-16s %s (%.1f us), then %s'
                  % ('pipeline total:', ARM_NAME[order[0][0]], order[0][1],
                     ', '.join('%s %.1f' % (ARM_NAME[a], v)
                               for a, v in order[1:])))

    # Paired within-rep differences, which is the only comparison the rotation
    # design actually licenses. A median of medians across reps hides whether
    # the winner won in every rep or in four of six.
    print()
    print('--- paired within-rep differences on the receiver window ---')
    print('%-10s %-34s %9s %9s %8s' % ('size', 'comparison', 'median', 'positive', 'p'))
    for size in sizes:
        for i, a in enumerate(arms):
            for b in arms[i + 1:]:
                diffs = []
                for rep in sorted({r['rep'] for r in rows}):
                    va = [r['e2e'] for r in rows
                          if r['arm'] == a and r['size'] == size
                          and r['rep'] == rep and r['e2e'] is not None]
                    vb = [r['e2e'] for r in rows
                          if r['arm'] == b and r['size'] == size
                          and r['rep'] == rep and r['e2e'] is not None]
                    if va and vb:
                        diffs.append(va[0] - vb[0])
                if not diffs:
                    continue
                pos = sum(1 for d in diffs if d > 0)
                neg = len(diffs) - pos
                print('%-10s %-34s %9.2f %5d/%-3d %8.3f'
                      % (kib(size), '%s minus %s' % (ARM_NAME[a], ARM_NAME[b]),
                         median(diffs), pos, len(diffs), sign_p(pos, neg)))

    # The rotation exists to make this small. Print it so the reader can check
    # rather than take it on faith.
    print()
    print('--- position effect (each cell against its own rep and size mean) ---')
    by_pos = defaultdict(list)
    for size in sizes:
        for rep in sorted({r['rep'] for r in rows}):
            grp = [r for r in rows if r['size'] == size and r['rep'] == rep
                   and r['e2e'] is not None]
            if len(grp) < 2:
                continue
            mean = sum(r['e2e'] for r in grp) / len(grp)
            for r in grp:
                by_pos[r['pos']].append(100.0 * (r['e2e'] - mean) / mean)
    for p in sorted(by_pos):
        print('  position %d: %+.2f%% of the cell mean  (n=%d)'
              % (p, median(by_pos[p]), len(by_pos[p])))

    mhz = [r['mhz'] for r in rows if r['mhz'] is not None]
    if mhz:
        print()
        print('  SM clock across all cells: %d .. %d MHz (median %d)'
              % (min(mhz), max(mhz), median(mhz)))


def main():
    args = sys.argv[1:]
    if not args:
        args = ['data/payload_runs_paced25.csv',
                'data/payload_runs_unsaturated.csv']
    labels = {
        'paced25': 'PASS A: sender paced 25 us at every size (the regime every '
                   'earlier table used)',
        'unsaturated': 'PASS B: sender paced so no arm saturates (the only '
                       'regime where transport means latency)',
    }
    for path in args:
        label = next((v for k, v in labels.items() if k in path), path)
        try:
            report(path, label)
        except FileNotFoundError:
            print('missing: %s' % path)


if __name__ == '__main__':
    main()
