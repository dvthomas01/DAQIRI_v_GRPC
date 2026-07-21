#pragma once
// util_sampler.h — background CPU (/proc/stat) and GPU (NVML) utilization sampler.
//
// Usage:
//   UtilSampler sampler(/*interval_ms=*/10);
//   sampler.start();
//   // ... run benchmark ...
//   float cpu = sampler.cpu_pct();
//   float gpu = sampler.gpu_pct();
//   sampler.stop();
//
// Reads /proc/stat for CPU deltas. Uses NVML for GPU utilization.
// Both values are stored as exponential moving averages (alpha = 0.2) so they
// represent roughly the last few seconds of activity, not a single sample.
// Thread-safe: cpu_pct()/gpu_pct() may be called from any thread.

#include <atomic>
#include <chrono>
#include <cstring>
#include <fstream>
#include <thread>

#include <nvml.h>

class UtilSampler {
public:
    explicit UtilSampler(int interval_ms = 10)
        : interval_ms_(interval_ms), running_(false),
          cpu_pct_(0.0f), gpu_pct_(0.0f),
          nvml_ok_(false), device_(nullptr)
    {
        // Initialise NVML once; if it fails we just report 0 for GPU util.
        if (nvmlInit_v2() == NVML_SUCCESS) {
            if (nvmlDeviceGetHandleByIndex_v2(0, &device_) == NVML_SUCCESS) {
                nvml_ok_ = true;
            }
        }
    }

    ~UtilSampler() {
        stop();
        if (nvml_ok_) nvmlShutdown();
    }

    // Non-copyable
    UtilSampler(const UtilSampler&)            = delete;
    UtilSampler& operator=(const UtilSampler&) = delete;

    void start() {
        if (running_.exchange(true)) return;  // already running
        thread_ = std::thread(&UtilSampler::loop, this);
    }

    void stop() {
        if (!running_.exchange(false)) return;
        thread_.join();
    }

    float cpu_pct() const { return cpu_pct_.load(std::memory_order_relaxed); }
    float gpu_pct() const { return gpu_pct_.load(std::memory_order_relaxed); }

private:
    // ── /proc/stat CPU snapshot ───────────────────────────────────────────────
    struct CpuTick {
        uint64_t user = 0, nice = 0, system = 0, idle = 0,
                 iowait = 0, irq = 0, softirq = 0, steal = 0;
        uint64_t total() const {
            return user + nice + system + idle + iowait + irq + softirq + steal;
        }
        uint64_t busy() const { return total() - idle - iowait; }
    };

    static CpuTick read_cpu_tick() {
        CpuTick t;
        std::ifstream f("/proc/stat");
        std::string tag;
        if (!(f >> tag)) return t;          // "cpu"
        f >> t.user >> t.nice >> t.system >> t.idle
          >> t.iowait >> t.irq >> t.softirq >> t.steal;
        return t;
    }

    void loop() {
        constexpr float alpha = 0.2f;       // EMA smoothing factor
        CpuTick prev = read_cpu_tick();

        while (running_.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(interval_ms_));

            // ── CPU util ─────────────────────────────────────────────────────
            CpuTick cur = read_cpu_tick();
            const uint64_t dtotal = cur.total() - prev.total();
            const uint64_t dbusy  = cur.busy()  - prev.busy();
            const float raw_cpu   = (dtotal > 0)
                ? static_cast<float>(dbusy) / static_cast<float>(dtotal) * 100.0f
                : 0.0f;
            const float smoothed_cpu = alpha * raw_cpu
                + (1.0f - alpha) * cpu_pct_.load(std::memory_order_relaxed);
            cpu_pct_.store(smoothed_cpu, std::memory_order_relaxed);
            prev = cur;

            // ── GPU util ─────────────────────────────────────────────────────
            if (nvml_ok_) {
                nvmlUtilization_t u{};
                if (nvmlDeviceGetUtilizationRates(device_, &u) == NVML_SUCCESS) {
                    const float raw_gpu = static_cast<float>(u.gpu);
                    const float smoothed_gpu = alpha * raw_gpu
                        + (1.0f - alpha) * gpu_pct_.load(std::memory_order_relaxed);
                    gpu_pct_.store(smoothed_gpu, std::memory_order_relaxed);
                }
            }
        }
    }

    int                   interval_ms_;
    std::atomic<bool>     running_;
    std::atomic<float>    cpu_pct_;
    std::atomic<float>    gpu_pct_;
    bool                  nvml_ok_;
    nvmlDevice_t          device_;
    std::thread           thread_;
};
