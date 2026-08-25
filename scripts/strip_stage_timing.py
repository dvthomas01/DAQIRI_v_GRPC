#!/usr/bin/env python3
"""Reconstruct the pre-stage-timing version of bench_daqiri_roce_pipeline.cc.

The file was untracked before commit 035d8e8, so git has no parent revision to
diff against and the pre-change binary was overwritten by the rebuild. This
script removes the eleven additions by exact match and refuses to write
anything if even one of them fails to match, so the reconstruction is checked
rather than assumed.

Usage: strip_stage_timing.py <in.cc> <out.cc>
"""
import sys

EDITS = [
    # 1. worker signature
    ("""    bool                       zero_copy,
    bool                       stage_timing,
""",
     """    bool                       zero_copy,
""", 1),

    # 2. the three vectors and their reserve
    ("""
    // Stage timers, mirroring bench_grpc_server.cc exactly so the two pipelines
    // can be decomposed with one instrument instead of two. Same three
    // intervals, same clock, same placement relative to fft.execute(). Off by
    // default so ordinary runs stay unperturbed; each steady_clock read is
    // about 20 ns against a per-message budget in the tens of microseconds.
    std::vector<double> st_lookup_us;   // device-pointer cache lookup
    std::vector<double> st_realign_us;  // D2D realign enqueue (normally absent)
    std::vector<double> st_fftcall_us;  // wall time of fft.execute()
    if (stage_timing) {
        st_lookup_us.reserve(static_cast<size_t>(n_expected));
        st_realign_us.reserve(static_cast<size_t>(n_expected));
        st_fftcall_us.reserve(static_cast<size_t>(n_expected));
    }
""", "", 1),

    # 3. hot-loop locals
    ("""            const bool st = stage_timing;
            std::chrono::steady_clock::time_point ts_a, ts_b, ts_c, ts_d;
""", "", 1),

    # 4/5/6. the four timestamp reads
    ("""                if (st) ts_a = std::chrono::steady_clock::now();
""", "", 1),
    ("""                if (st) ts_b = std::chrono::steady_clock::now();
""", "", 1),
    ("""                    if (st) ts_c = std::chrono::steady_clock::now();
""", "", 2),

    # 7. the push block after fft.execute()
    ("""                if (st) {
                    ts_d = std::chrono::steady_clock::now();
                    auto us = [](const std::chrono::steady_clock::time_point& a,
                                 const std::chrono::steady_clock::time_point& b) {
                        return std::chrono::duration<double>(b - a).count() * 1e6;
                    };
                    st_lookup_us.push_back(us(ts_a, ts_b));
                    st_realign_us.push_back(us(ts_b, ts_c));
                    st_fftcall_us.push_back(us(ts_c, ts_d));
                }
""", "", 1),

    # 8. the cleanup-time print
    ("""    if (stage_timing) {
        auto stage = [](std::vector<double> v, const char* name) {
            if (v.empty()) return;
            std::sort(v.begin(), v.end());
            auto q = [&](int p) {
                return v[static_cast<size_t>(
                    std::min<int>(static_cast<int>(v.size()) * p / 100,
                                  static_cast<int>(v.size()) - 1))];
            };
            std::cout << "  " << name << " p50/p99 : " << q(50) << " / "
                      << q(99) << " us  (n=" << v.size() << ")\\n";
        };
        std::cout << "\\n---- Stage timers (same intervals as bench_grpc_server) ----\\n";
        stage(st_lookup_us,  "register+lookup");
        stage(st_realign_us, "realign enqueue");
        stage(st_fftcall_us, "fft call (wall)");
        std::cout << "  note: 'fft call (wall)' minus the CSV fft_exec_us is"
                     " launch + sync overhead.\\n"
                  << "------------------------------------------------\\n";
    }
""", "", 1),

    # 9. argument parsing
    ("""        else if (!strcmp(argv[i], "--stage-timing"))            stage_timing = true;
""", "", 1),

    # 10. the flag itself
    ("""    bool stage_timing = false;
""", "", 1),

    # 11. thread call site
    ("""                       buf_size, total_send, warmup, zero_copy, stage_timing,
""",
     """                       buf_size, total_send, warmup, zero_copy,
""", 1),
]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        text = f.read().decode("utf-8").replace("\r\n", "\n")

    failures = []
    for i, (old, new, count) in enumerate(EDITS, 1):
        found = text.count(old)
        if found != count:
            failures.append("edit %d: expected %d match(es), found %d" % (i, count, found))
            continue
        text = text.replace(old, new)

    if failures:
        print("REFUSING TO WRITE. Reconstruction is not exact:")
        for f in failures:
            print("  " + f)
        sys.exit(1)

    for token in ("stage_timing", "st_lookup_us", "st_realign_us",
                  "st_fftcall_us", "--stage-timing", "ts_a", "ts_b",
                  "ts_c", "ts_d"):
        if token in text:
            print("REFUSING TO WRITE. Residual token still present: " + token)
            sys.exit(1)

    with open(dst, "wb") as f:
        f.write(text.encode("utf-8"))
    print("OK: wrote %s, %d lines, no residual stage-timing tokens"
          % (dst, text.count("\n")))


main()
