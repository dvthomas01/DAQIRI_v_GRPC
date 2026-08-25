#!/usr/bin/env bash
# Narrow down the missing GPU activity.
# If the API trace contains cudaLaunchKernel but the KERNEL table is absent,
# the workload ran and CUPTI simply never flushed its GPU-side buffers. That is
# a collection problem with a known set of fixes. If there are no launches
# either, the problem is somewhere else entirely and the fixes would be wasted.
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin

echo "=== what the opt server's API trace actually contains ==="
python3 - <<'PY'
import sqlite3
from collections import Counter
for tag in ("opt_1048576_1", "extbuf_1048576_1", "daq_1048576_1"):
    cx = sqlite3.connect("/tmp/prof/pp_%s.sqlite" % tag)
    S = {r[0]: r[1] for r in cx.execute("SELECT id, value FROM StringIds")}
    c = Counter()
    for (nid,) in cx.execute("SELECT nameId FROM CUPTI_ACTIVITY_KIND_RUNTIME"):
        c[S.get(nid, "?")] += 1
    print("\n--- %s : %d API calls ---" % (tag, sum(c.values())))
    for nm, n in c.most_common(8):
        print("    %-40s %6d" % (nm, n))
PY

echo
echo "=== nsys options that affect GPU-side buffer flushing ==="
nsys profile --help 2>&1 | grep -a -i -e flush -e 'cuda-mem' -e 'cudabacktrace' -e 'wait' -e 'kill' | head -20
