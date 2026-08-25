#!/usr/bin/env python3
"""Where in the run do the 20 captured CUDA calls actually sit?

If they cluster in the final milliseconds, CUPTI only ever saved one final
buffer. If they are scattered, CUPTI was selectively blind. The answer picks
the fix, so measure it rather than guess.
"""
import sqlite3

p = "/tmp/proftest/f_100ms.sqlite"
cx = sqlite3.connect(p)
S = {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}

# Session span from the OS-runtime trace, which did work on all threads.
lo, hi = list(cx.execute("SELECT min(start), max(end) FROM OSRT_API"))[0]
print("session span from OS runtime trace : %.3f s" % ((hi - lo) / 1e9))

rows = sorted(cx.execute(
    "SELECT start, end, globalTid, nameId FROM CUPTI_ACTIVITY_KIND_RUNTIME"))
print("\n  t_rel(s)   dur(us)  thread   call")
for st, en, tid, nid in rows:
    print("  %8.3f  %8.1f  %-6d  %s"
          % ((st - lo) / 1e9, (en - st) / 1e3, tid & 0xFFFFFF, S.get(nid, "?")))

print("\nOS-runtime activity per thread (shows which thread did the work):")
c = {}
for tid, st, en in cx.execute("SELECT globalTid, start, end FROM OSRT_API"):
    d = c.setdefault(tid & 0xFFFFFF, [0, 0])
    d[0] += 1
    d[1] += en - st
for tid, (n, tot) in sorted(c.items(), key=lambda kv: -kv[1][0]):
    print("   thread %-8d %6d calls  %8.3f s in syscalls" % (tid, n, tot / 1e9))
