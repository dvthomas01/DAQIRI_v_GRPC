#!/usr/bin/env bash
export PATH=/usr/local/cuda-13/bin:/usr/bin:/bin
echo "=== nsys stats on the opt report ==="
nsys stats --force-export=true \
    --report cuda_api_sum --report cuda_gpu_kern_sum \
    /tmp/proftest/v2_nosrt.nsys-rep 2>&1 | head -40

echo
echo "=== every non-empty table, opt vs daq ==="
python3 - <<'PY'
import sqlite3
for p, lbl in (("/tmp/proftest/v2_nosrt.sqlite", "opt"),
               ("/tmp/prof/pp_daq_1048576_1.sqlite", "daq")):
    cx = sqlite3.connect(p)
    print("\n--- %s (%s) ---" % (lbl, p))
    for (t,) in cx.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
        try:
            n = list(cx.execute("SELECT count(*) FROM [%s]" % t))[0][0]
        except Exception:
            continue
        if n and not t.startswith("ENUM_"):
            print("    %-45s %8d" % (t, n))
PY
