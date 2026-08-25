#!/usr/bin/env python3
"""Dump nsys's own diagnostic events. These carry the collector's explanation
for anything it could not trace."""
import sqlite3
for p, lbl in (("/tmp/proftest/v2_nosrt.sqlite", "opt (broken)"),
               ("/tmp/prof/pp_daq_1048576_1.sqlite", "daq (good)")):
    cx = sqlite3.connect(p)
    S = {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}
    cols = [c[1] for c in cx.execute("PRAGMA table_info(DIAGNOSTIC_EVENT)")]
    print("\n===== %s =====" % lbl)
    print("cols:", cols)
    for row in cx.execute("SELECT * FROM DIAGNOSTIC_EVENT"):
        d = dict(zip(cols, row))
        txt = d.get("text")
        if isinstance(txt, int):
            txt = S.get(txt, txt)
        print("  [%s] %s" % (d.get("severity"), txt))
