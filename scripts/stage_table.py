#!/usr/bin/env python3
"""Turn data/stage_runs.csv into a per-stage comparison of the four arms.

Every column is a per-message p50 taken inside one run, then the median across
reps. The spread across reps is printed next to each figure so a number that
moved between reps cannot be read as a stable result.

The decomposition is additive inside the e2e window, which both binaries define
identically as buffer-in-hand to post-FFT:

    e2e = register+lookup + realign enqueue + fft call (wall) + residual

and the fft call splits into the kernel and everything around it:

    fft call (wall) = fft_exec (CUDA event) + launch and sync

Residual is what e2e contains that the three stage timers do not: the metrics
bookkeeping and, for the gRPC arms, the part of the handler that runs after the
timers stop. It is reported rather than hidden so the columns add up in view.
"""
import csv
import statistics
import sys
from collections import defaultdict

ARM_NAME = {
    'base':   'gRPC baseline',
    'opt':    'gRPC optimized',
    'daq':    'DAQiri',
    'extbuf': 'gRPC over RDMA',
}
ORDER = ['base', 'opt', 'daq', 'extbuf']


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def med(vals):
    v = [x for x in vals if x is not None]
    return statistics.median(v) if v else None


def spread(vals):
    v = [x for x in vals if x is not None]
    return (max(v) - min(v)) if len(v) > 1 else 0.0


def fmt(v, sp=None):
    if v is None:
        return '     n/a'
    s = '%8.2f' % v
    if sp is not None and sp > 0:
        s += ' +-%-6.2f' % (sp / 2.0)
    else:
        s += ' ' * 9
    return s


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'data/stage_runs.csv'
    rows = defaultdict(list)
    with open(path, newline='') as fh:
        for r in csv.DictReader(fh):
            rows[(int(r['size']), r['arm'])].append(r)

    for size in sorted({k[0] for k in rows}, reverse=True):
        kb = size * 4 // 1024
        print('=' * 86)
        print('PAYLOAD %d samples = %d KB   (p50 per run, median across reps, '
              'half-range shown)' % (size, kb))
        print('=' * 86)

        table = {}
        for arm in ORDER:
            rs = rows.get((size, arm))
            if not rs:
                continue
            cols = {}
            for key, field in (('e2e', 'e2e_p50'), ('fft', 'fft_p50'),
                               ('lookup', 'lookup_p50'),
                               ('realign', 'realign_p50'),
                               ('fftcall', 'fftcall_p50')):
                vals = [num(r[field]) for r in rs]
                cols[key] = (med(vals), spread(vals))
            # derived
            fc, fx = cols['fftcall'][0], cols['fft'][0]
            cols['launchsync'] = ((fc - fx) if (fc is not None and fx is not None)
                                  else None, 0.0)
            parts = [cols[k][0] for k in ('lookup', 'realign', 'fftcall')]
            if cols['e2e'][0] is not None and all(p is not None for p in parts):
                cols['residual'] = (cols['e2e'][0] - sum(parts), 0.0)
            else:
                cols['residual'] = (None, 0.0)
            cols['_n'] = (med([num(r['n']) for r in rs]), 0.0)
            cols['_mhz'] = (med([num(r['sm_mhz']) for r in rs]), 0.0)
            cols['_reps'] = (len(rs), 0.0)
            table[arm] = cols

        hdr = ('%-18s %-17s %-17s %-17s %-17s' %
               ('stage', 'gRPC baseline', 'gRPC optimized', 'DAQiri',
                'gRPC over RDMA'))
        print(hdr)
        print('-' * 86)
        for key, lbl in (('e2e', 'e2e (total)'),
                         ('lookup', '  register+lookup'),
                         ('realign', '  realign enqueue'),
                         ('fftcall', '  fft call (wall)'),
                         ('residual', '  residual'),
                         ('fft', 'of which kernel'),
                         ('launchsync', 'of which launch+sync')):
            line = '%-18s' % lbl
            for arm in ORDER:
                c = table.get(arm)
                line += ' ' + (fmt(*c[key]) if c else fmt(None))
            print(line)
        print('-' * 86)
        line = '%-18s' % 'messages / SM MHz'
        for arm in ORDER:
            c = table.get(arm)
            if c:
                line += ' %8d/%-8d' % (c['_n'][0] or 0, c['_mhz'][0] or 0)
            else:
                line += ' %-17s' % '  n/a'
        print(line)

        # Where the gap lives: every arm against DAQiri, stage by stage.
        if 'daq' in table:
            print()
            print('MINUS DAQiri, stage by stage (positive = slower than DAQiri)')
            for arm in ORDER:
                if arm == 'daq' or arm not in table:
                    continue
                bits = []
                for key, lbl in (('e2e', 'e2e'), ('lookup', 'lookup'),
                                 ('realign', 'realign'), ('fft', 'kernel'),
                                 ('launchsync', 'launch+sync'),
                                 ('residual', 'residual')):
                    a, b = table[arm][key][0], table['daq'][key][0]
                    if a is None or b is None:
                        continue
                    bits.append('%s %+.2f' % (lbl, a - b))
                print('  %-16s %s' % (ARM_NAME[arm], '   '.join(bits)))
        print()


if __name__ == '__main__':
    main()
