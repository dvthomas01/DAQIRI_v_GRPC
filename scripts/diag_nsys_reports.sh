#!/usr/bin/env bash
# Why did the profiled server runs produce a report with no CUDA in it?
# The runs themselves clearly worked (the log has n_measured), so the report is
# being truncated rather than the workload failing.
for tag in opt_1048576_1 base_1048576_1 extbuf_1048576_1 daq_1048576_1; do
    echo "================ $tag ================"
    echo "--- nsys lines in the log ---"
    grep -a -i -e nsys -e 'Generating' -e 'report' -e 'WARNING' -e 'ERROR' -e 'Failed' \
        -e 'Collecting' -e 'signal' /tmp/pp_${tag}_p1.log | head -12
    echo "--- last 5 lines of the log ---"
    tail -5 /tmp/pp_${tag}_p1.log
    echo "--- report size ---"
    ls -l /tmp/prof/pp_${tag}.nsys-rep 2>&1 | awk '{print $5, $9}'
    echo "--- tables in the export ---"
    python3 - "$tag" <<'PY'
import sqlite3, sys
p = "/tmp/prof/pp_%s.sqlite" % sys.argv[1]
try:
    cx = sqlite3.connect(p)
    t = sorted(r[0] for r in cx.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"))
    cu = [x for x in t if 'CUPTI' in x or 'OSRT' in x]
    print("  total tables: %d ; cupti/osrt: %s" % (len(t), cu if cu else "NONE"))
except Exception as e:
    print("  cannot open:", e)
PY
    echo
done
