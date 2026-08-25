#!/usr/bin/env python3
"""
Turn nsys .sqlite exports into a per-stage decomposition of each pipeline.

WHY NOT `nsys stats`
--------------------
The canned reports summarise each domain separately: kernels here, CUDA API
there, syscalls somewhere else. They double count, because a cudaEventSynchronize
that blocks in an ioctl appears in BOTH the CUDA API report and the OS runtime
report. Adding those two numbers produces a total larger than the wall time,
which is exactly the kind of arithmetic that makes a profile untrustworthy.

So this builds ONE partition of the consumer thread's wall clock, where every
nanosecond is counted once:

    waiting-in-CUDA   time inside a blocking CUDA API (event/stream sync)
    enqueue-in-CUDA   time inside a non-blocking CUDA API (launch, memcpy async)
    blocked-in-kernel time in a syscall that is NOT inside any CUDA call
                      (this is the transport: poll, futex, ibv doorbell ioctls)
    cpu-work          traced by nothing, i.e. our own code running on the CPU

and separately, the GPU's own view:

    kernel busy       sum of kernel durations
    memcpy            sum of memcpy durations, by direction
    gpu idle          the rest of the message cycle

The two views are not added together. They are two different clocks looking at
the same interval, and the interesting question is where they disagree.

MESSAGE BOUNDARIES
------------------
Each message ends when the consumer blocks on the transform's completion, so
the ends of the blocking sync calls are used as boundaries. That is a property
of how all three programs are written, not an assumption about timing, which is
why it survives the profiler's overhead.

STEADY STATE
------------
The first 25% and last 10% of message cycles are dropped. Plan setup, first
touch of every page, and the drain at the end are all real costs but they are
not what a sustained pipeline pays, and at these message counts they would move
a median.
"""
import sqlite3, sys, os, glob, re, statistics
from collections import defaultdict

# CUDA calls that BLOCK the calling thread. Everything else in the runtime API
# is treated as enqueue cost. Getting this list wrong moves time between two
# columns of the output, so it is explicit rather than pattern matched.
#
# Names are NORMALISED first. CUPTI reports 'cudaEventSynchronize_v3020' and
# 'cudaStreamSynchronize_ptsz', not the bare names, so a literal match silently
# classifies every blocking wait as enqueue and then reports a thread that
# never blocks. That happened on the first run of this script.
BLOCKING = {
    'cudaEventSynchronize', 'cudaStreamSynchronize', 'cudaDeviceSynchronize',
    'cudaMemcpy', 'cudaFreeHost', 'cudaHostUnregister', 'cuStreamSynchronize',
    'cuEventSynchronize', 'cuCtxSynchronize',
}
SPIN = {'cudaEventQuery', 'cudaStreamQuery', 'cuEventQuery', 'cuStreamQuery'}

_SUFFIX = re.compile(r'(_v\d+|_ptsz|_ptds)+$')


def norm(name):
    return _SUFFIX.sub('', name)


def tables(cx):
    return {r[0] for r in cx.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view')")}


def strings(cx):
    return {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}


def merge(iv):
    """Union of intervals, as a sorted non-overlapping list."""
    if not iv:
        return []
    iv = sorted(iv)
    out = [list(iv[0])]
    for s, e in iv[1:]:
        if s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def overlap(a, b):
    """Total overlap between two merged interval lists."""
    i = j = 0
    tot = 0
    while i < len(a) and j < len(b):
        lo = max(a[i][0], b[j][0])
        hi = min(a[i][1], b[j][1])
        if hi > lo:
            tot += hi - lo
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return tot


def clip(iv, lo, hi):
    out = []
    for s, e in iv:
        s2, e2 = max(s, lo), min(e, hi)
        if e2 > s2:
            out.append((s2, e2))
    return out


def subtract(a, b):
    """a minus b, both merged interval lists."""
    out = []
    j = 0
    for s, e in a:
        cur = s
        k = j
        while k < len(b) and b[k][0] < e:
            if b[k][1] > cur:
                if b[k][0] > cur:
                    out.append((cur, min(b[k][0], e)))
                cur = max(cur, b[k][1])
                if cur >= e:
                    break
            k += 1
        if cur < e:
            out.append((cur, e))
        while j < len(b) and b[j][1] <= e:
            j += 1
    return [x for x in out if x[1] > x[0]]


def per_cycle(merged, cycles):
    """Overlap of a merged interval list with each cycle, in order.

    This is the whole reason the script exists in this shape. Summing a
    component over the run and dividing by the cycle count reports the MEAN,
    and on this receive path the cycle distribution is punctuated: at 16 KB the
    median cycle is 17.5 us against a mean of 180.6, so the mean is set by the
    drain and says nothing about a steady-state message. Every component is
    measured per cycle here so the summary can take a median.
    """
    out = []
    j = 0
    for a, b in cycles:
        while j < len(merged) and merged[j][1] <= a:
            j += 1
        k, tot = j, 0
        while k < len(merged) and merged[k][0] < b:
            lo2, hi2 = max(merged[k][0], a), min(merged[k][1], b)
            if hi2 > lo2:
                tot += hi2 - lo2
            k += 1
        out.append(tot)
    return out


def analyze(path):
    cx = sqlite3.connect(path)
    T = tables(cx)
    r = {'file': os.path.basename(path)}
    # A report that cannot be decomposed is REPORTED, not dropped. Silently
    # skipping one arm leaves a table that looks complete and compares three
    # pipelines when it was asked to compare four.
    if 'CUPTI_ACTIVITY_KIND_KERNEL' not in T:
        r['skip'] = 'no kernel table (process launched no CUDA work)'
        return r
    S = strings(cx)

    # ---- GPU: kernels -----------------------------------------------------
    kern = list(cx.execute(
        "SELECT start, end, COALESCE(shortName, demangledName) FROM "
        "CUPTI_ACTIVITY_KIND_KERNEL ORDER BY start"))
    kern = [(s, e, S.get(n, str(n))) for s, e, n in kern]
    if not kern:
        r['skip'] = 'kernel table present but empty'
        return r

    # ---- GPU: memcpy ------------------------------------------------------
    mem = []
    if 'CUPTI_ACTIVITY_KIND_MEMCPY' in T:
        cols = {c[1] for c in cx.execute(
            "PRAGMA table_info(CUPTI_ACTIVITY_KIND_MEMCPY)")}
        kindcol = 'copyKind' if 'copyKind' in cols else None
        q = "SELECT start, end, bytes%s FROM CUPTI_ACTIVITY_KIND_MEMCPY ORDER BY start" % (
            ", " + kindcol if kindcol else "")
        for row in cx.execute(q):
            mem.append((row[0], row[1], row[2], row[3] if kindcol else -1))

    # ---- CPU: runtime API, find the consumer thread ------------------------
    if 'CUPTI_ACTIVITY_KIND_RUNTIME' not in T:
        r['skip'] = 'no CUDA runtime API table'
        return r
    rt = list(cx.execute(
        "SELECT start, end, globalTid, nameId FROM CUPTI_ACTIVITY_KIND_RUNTIME"))
    per_thread = defaultdict(int)
    for s, e, tid_, nid in rt:
        nm = norm(S.get(nid, ''))
        if 'Launch' in nm or nm in BLOCKING:
            per_thread[tid_] += 1
    if not per_thread:
        r['skip'] = 'no thread issues launches or blocking syncs'
        return r
    tid = max(per_thread, key=per_thread.get)
    r['consumer_tid'] = tid
    r['n_threads_cuda'] = len({t for _, _, t, _ in rt})

    mine = [(s, e, norm(S.get(n, str(n)))) for s, e, t, n in rt if t == tid]
    mine.sort()

    # ---- message boundaries: ends of blocking syncs on the consumer thread --
    bounds = [e for s, e, n in mine if n in BLOCKING]
    if len(bounds) < 12:
        # Fall back to kernel clustering if this program does not block per
        # message. Recorded in the output so it is never silently assumed.
        r['boundary'] = 'kernel-gap'
        gaps = []
        for i in range(1, len(kern)):
            gaps.append(kern[i][0] - kern[i - 1][1])
        thr = max(2000, statistics.median(gaps) if gaps else 2000)
        bounds = []
        for i in range(1, len(kern)):
            if kern[i][0] - kern[i - 1][1] > thr:
                bounds.append(kern[i - 1][1])
    else:
        r['boundary'] = 'sync-end'

    bounds.sort()
    n = len(bounds)
    lo_i, hi_i = int(n * 0.25), int(n * 0.90)
    cyc = [(bounds[i], bounds[i + 1]) for i in range(lo_i, min(hi_i, n - 1))]
    if len(cyc) < 5:
        r['skip'] = 'only %d steady-state cycles (need 5); %d boundaries total' % (
            len(cyc), n)
        return r
    r['n_cycles'] = len(cyc)
    lo, hi = cyc[0][0], cyc[-1][1]
    span = hi - lo
    r['span_us'] = span / 1000.0
    r['cycle_us'] = statistics.median([(b - a) for a, b in cyc]) / 1000.0

    # ---- partition the consumer thread's wall clock, PER CYCLE -------------
    blk = merge(clip([(s, e) for s, e, nm in mine if nm in BLOCKING], lo, hi))
    spin = merge(clip([(s, e) for s, e, nm in mine if nm in SPIN], lo, hi))
    allcuda = merge(clip([(s, e) for s, e, nm in mine], lo, hi))

    osrt = []
    if 'OSRT_API' in T:
        osrt = [(s, e, norm(S.get(nid, str(nid)))) for s, e, t, nid in cx.execute(
            "SELECT start, end, globalTid, nameId FROM OSRT_API WHERE globalTid = ?",
            (tid,)) if e is not None]
    osrt_iv = merge(clip([(s, e) for s, e, _ in osrt], lo, hi))
    osrt_out_iv = subtract(osrt_iv, allcuda)

    v_blk = per_cycle(blk, cyc)
    v_spin = per_cycle(spin, cyc)
    v_cuda = per_cycle(allcuda, cyc)
    v_osrt = per_cycle(osrt_out_iv, cyc)
    v_len = [b - a for a, b in cyc]
    v_enq = [v_cuda[i] - v_blk[i] - v_spin[i] for i in range(len(cyc))]
    v_work = [v_len[i] - v_cuda[i] - v_osrt[i] for i in range(len(cyc))]

    c = len(cyc)
    M = lambda v: statistics.median(v) / 1000.0
    r['cpu'] = {
        'wait_cuda_us': M(v_blk),
        'spin_cuda_us': M(v_spin),
        'enqueue_cuda_us': M(v_enq),
        'blocked_syscall_us': M(v_osrt),
        'cpu_work_us': M(v_work),
    }
    # The five components are a PARTITION of each cycle, so within any single
    # cycle they must sum to that cycle's length. Medians of the five need not
    # sum to the median cycle, and it would be wrong to force them to, so the
    # check is the worst per-cycle residual instead.
    r['partition_err_us'] = max(
        abs(v_blk[i] + v_spin[i] + v_enq[i] + v_osrt[i] + v_work[i] - v_len[i])
        for i in range(c)) / 1000.0

    # top syscalls outside CUDA, which is where the transport shows up
    byname = defaultdict(list)
    for s, e, nm in osrt:
        byname[nm].append((s, e))
    sysc = []
    for nm, iv in byname.items():
        kept = clip(iv, lo, hi)
        ivm = subtract(merge(kept), allcuda)
        if not ivm:
            continue
        sysc.append((nm, len(kept) / float(c),
                     statistics.median(per_cycle(ivm, cyc)) / 1000.0,
                     sum(e - s for s, e in ivm) / 1000.0 / c))
    r['syscalls'] = sorted(sysc, key=lambda x: -x[3])[:6]

    # top CUDA APIs by time per cycle
    byapi = defaultdict(list)
    for s, e, nm in mine:
        byapi[nm].append((s, e))
    apis = []
    for nm, iv in byapi.items():
        ivc = clip(iv, lo, hi)
        if not ivc:
            continue
        apis.append((nm, len(ivc) / c,
                     statistics.median(per_cycle(merge(ivc), cyc)) / 1000.0,
                     sum(e - s for s, e in ivc) / 1000.0 / c))
    r['apis'] = sorted(apis, key=lambda x: -x[3])[:8]

    # ---- GPU view ---------------------------------------------------------
    kin = [(s, e, nm) for s, e, nm in kern if e > lo and s < hi]
    r['gpu_busy_us'] = statistics.median(
        per_cycle(merge([(s, e) for s, e, _ in kin]), cyc)) / 1000.0
    bykern = defaultdict(list)
    for s, e, nm in kin:
        bykern[nm].append((s, e))
    ks = []
    for nm, iv in bykern.items():
        ivc = clip(iv, lo, hi)
        ks.append((nm, len(ivc) / c,
                   statistics.median(per_cycle(merge(ivc), cyc)) / 1000.0,
                   sum(e - s for s, e in ivc) / 1000.0 / c))
    r['kernels'] = sorted(ks, key=lambda x: -x[3])[:6]

    mcp = defaultdict(lambda: [0, 0, 0.0])
    for s, e, by, kind in mem:
        if e <= lo or s >= hi:
            continue
        mcp[kind][0] += 1
        mcp[kind][1] += by or 0
        mcp[kind][2] += (min(e, hi) - max(s, lo))
    r['memcpy'] = [(k, v[0] / c, v[1] / max(v[0], 1), v[2] / 1000.0 / c)
                   for k, v in sorted(mcp.items())]
    cx.close()
    return r


MEMKIND = {0: 'Unknown', 1: 'HtoD', 2: 'DtoH', 3: 'HtoA', 4: 'AtoH', 5: 'AtoA',
           6: 'AtoD', 7: 'DtoA', 8: 'DtoD', 9: 'HtoH', 10: 'PtoP', -1: '?'}


def label(fn):
    m = re.match(r'pp_([a-z]+)_(\d+)_(\d+)', fn)
    return (m.group(1), int(m.group(2)), int(m.group(3))) if m else (fn, 0, 0)


def agg(rs, key):
    """Median across reps of a per-rep [(name, count, median_us, mean_us)] list.

    The summary lines are medians across reps, so the detail lines have to be
    too. Taking them from rs[0] mixed one rep's kernels with three reps' totals
    and produced a nanosleep larger than the message cycle it sat inside.
    """
    by = defaultdict(lambda: ([], [], []))
    for r in rs:
        for row in r.get(key, []):
            nm, cnt, us, mean_us = row
            by[nm][0].append(cnt)
            by[nm][1].append(us)
            by[nm][2].append(mean_us)
    out = [(nm, statistics.median(c), statistics.median(u), statistics.median(m))
           for nm, (c, u, m) in by.items()]
    return sorted(out, key=lambda x: -x[3])


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else '/tmp/prof'
    files = sorted(glob.glob(os.path.join(d, 'pp_*.sqlite')))
    if not files:
        print("no sqlite files in", d)
        return
    rows, skipped = [], []
    for f in files:
        try:
            r = analyze(f)
        except Exception as ex:
            skipped.append((os.path.basename(f), 'EXCEPTION: %s' % ex))
            continue
        r['arm'], r['size'], r['rep'] = label(os.path.basename(f))
        if 'skip' in r:
            skipped.append((os.path.basename(f), r['skip']))
        else:
            rows.append(r)

    if skipped:
        print("SKIPPED %d of %d reports:" % (len(skipped), len(files)))
        for fn, why in skipped:
            print("   %-28s %s" % (fn, why))

    for size in sorted({r['size'] for r in rows}, reverse=True):
        kb = size * 4 // 1024
        print("\n" + "=" * 78)
        print("PAYLOAD %d samples = %d KB   (per-message medians, then median across reps)"
              % (size, kb))
        print("=" * 78)
        for arm in ['base', 'opt', 'daq', 'extbuf']:
            rs = [r for r in rows if r['arm'] == arm and r['size'] == size]
            if not rs:
                print("\n--- %s   NO USABLE PROFILE ---" % arm)
                continue
            print("\n--- %s   (%d reps, %s boundaries, %d cycles/rep) ---" % (
                arm, len(rs), rs[0]['boundary'],
                int(statistics.median([r['n_cycles'] for r in rs]))))
            med = lambda k: statistics.median([r['cpu'][k] for r in rs])
            cyc = statistics.median([r['cycle_us'] for r in rs])
            span_per = statistics.median([r['span_us'] / r['n_cycles'] for r in rs])
            print("  message cycle (wall, profiled)      %8.2f us  [mean %.2f]" % (cyc, span_per))
            print("  CONSUMER THREAD, one message:")
            print("    blocked in CUDA sync              %8.2f us" % med('wait_cuda_us'))
            print("    spinning in CUDA query            %8.2f us" % med('spin_cuda_us'))
            print("    enqueue / launch in CUDA          %8.2f us" % med('enqueue_cuda_us'))
            print("    blocked in syscall (transport)    %8.2f us" % med('blocked_syscall_us'))
            print("    our own CPU code                  %8.2f us" % med('cpu_work_us'))
            err = statistics.median([abs(r['partition_err_us']) for r in rs])
            print("    -- partition check, must be ~0    %8.2f us" % err)
            print("  GPU, one message:")
            print("    kernel busy                       %8.2f us" %
                  statistics.median([r['gpu_busy_us'] for r in rs]))
            for nm, cnt, us, mean_us in agg(rs, 'kernels')[:5]:
                print("      %-32s %6.2f us  x%.1f" % (nm[:32], us, cnt))
            mm = defaultdict(list)
            for r in rs:
                for k, cnt, by, us in r['memcpy']:
                    mm[k].append((cnt, by, us))
            if mm:
                for k, v in sorted(mm.items()):
                    print("    memcpy %-5s %9.0f B x%.1f     %8.2f us" % (
                        MEMKIND.get(k, k),
                        statistics.median([x[1] for x in v]),
                        statistics.median([x[0] for x in v]),
                        statistics.median([x[2] for x in v])))
            else:
                print("    memcpy                                none")
            print("  top syscalls outside CUDA:")
            for nm, cnt, us, mean_us in agg(rs, 'syscalls')[:4]:
                print("      %-32s %6.2f us  [mean %.2f]" % (nm[:32], us, mean_us))
            print("  top CUDA APIs:")
            for nm, cnt, us, mean_us in agg(rs, 'apis')[:5]:
                print("      %-32s %6.2f us  x%.1f" % (nm[:32], us, cnt))


if __name__ == '__main__':
    main()
