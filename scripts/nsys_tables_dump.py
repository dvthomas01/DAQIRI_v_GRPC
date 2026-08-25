#!/usr/bin/env python3
"""List the non-empty tables in an nsys sqlite export.

Used to find out where the GPU-side records went when
CUPTI_ACTIVITY_KIND_KERNEL is missing. Kernels can land in other tables
depending on how they were launched, so 'the kernel table is absent' is not the
same as 'no GPU work was recorded'.

Usage: nsys_tables_dump.py <export.sqlite> [...]
"""
import sqlite3
import sys

for db in sys.argv[1:]:
    print('== ' + db)
    con = sqlite3.connect(db)
    cur = con.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    names = [r[0] for r in cur.fetchall()]
    for n in names:
        try:
            cur.execute('SELECT COUNT(*) FROM "%s"' % n)
            c = cur.fetchone()[0]
        except sqlite3.Error:
            continue
        if c:
            print('   %-45s %8d' % (n, c))
    con.close()
    print()
