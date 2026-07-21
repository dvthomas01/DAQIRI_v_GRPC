#pragma once

#include <vector>
#include <algorithm>
#include <numeric>

// Per-buffer metrics captured during a benchmark run.
struct BufferMetrics {
    double e2e_latency_us      = 0.0;  // signal-gen timestamp → post-FFT
    double transfer_latency_us = 0.0;  // host→device copy (or DAQiri DMA callback latency)
    double wire_latency_us     = 0.0;  // client send_timestamp → server receive (transport)
    double fft_exec_us         = 0.0;  // cuFFT kernel execution only (CUDA events)
    double samples_per_sec     = 0.0;
    double buffers_per_sec     = 0.0;
    double mb_per_sec          = 0.0;
    float  cpu_util_pct        = 0.0f; // sampled from /proc/stat
    float  gpu_util_pct        = 0.0f; // nvmlDeviceGetUtilizationRates
    int    buffer_size_samples = 0;
    int    dropped_buffers     = 0;    // cumulative at time of this buffer
};

// Aggregate summary computed from a full run.
struct RunSummary {
    double p50_us            = 0.0;
    double p95_us            = 0.0;
    double p99_us            = 0.0;
    double min_us            = 0.0;
    double max_us            = 0.0;
    double mean_us           = 0.0;
    double jitter_p99_p50_us = 0.0;
    double throughput_mb_s   = 0.0;
    int    total_dropped     = 0;
    int    n_buffers         = 0;
};

// Compute a RunSummary from per-buffer E2E latencies.
// latencies_us is sorted in-place by this function.
inline RunSummary compute_summary(
    std::vector<double>& latencies_us,
    double               throughput_mb_s,
    int                  total_dropped)
{
    RunSummary s;
    if (latencies_us.empty()) return s;

    std::sort(latencies_us.begin(), latencies_us.end());
    const int n = static_cast<int>(latencies_us.size());

    auto pct = [&](int p) -> double {
        int idx = static_cast<int>(n * p / 100);
        if (idx >= n) idx = n - 1;
        return latencies_us[idx];
    };

    s.n_buffers         = n;
    s.min_us            = latencies_us.front();
    s.max_us            = latencies_us.back();
    s.mean_us           = std::accumulate(latencies_us.begin(), latencies_us.end(), 0.0) / n;
    s.p50_us            = pct(50);
    s.p95_us            = pct(95);
    s.p99_us            = pct(99);
    s.jitter_p99_p50_us = s.p99_us - s.p50_us;
    s.throughput_mb_s   = throughput_mb_s;
    s.total_dropped     = total_dropped;
    return s;
}
