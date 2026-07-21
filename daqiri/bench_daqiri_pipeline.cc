// bench_daqiri_pipeline.cc — M4/M5: DAQiri socket → H→D copy → cuFFT pipeline.
//
// Full end-to-end benchmark with complete metrics:
//   TX worker  : inject deterministic float32 signal via DAQiri socket
//   RX worker  : receive → cudaMemcpy H→D → cuFFT R2C → record metrics
//   Sampler    : background thread records CPU (/proc/stat) + GPU (NVML) util
//   Output     : per-buffer CSV (data/daqiri_pipeline_<bufsize>.csv)
//                + RunSummary printed to stdout
//
// Metrics captured per buffer (all columns in BufferMetrics):
//   e2e_latency_us      — burst-arrival → post-FFT  (RX-side wall-clock)
//   transfer_latency_us — H→D cudaMemcpy            (CUDA event)
//   fft_exec_us         — cuFFT R2C kernel           (CUDA event)
//   samples_per_sec, buffers_per_sec, mb_per_sec
//   cpu_util_pct        — /proc/stat EMA             (background sampler)
//   gpu_util_pct        — NVML EMA                   (background sampler)
//
// Usage (from repo root):
//   ./build/daqiri/bench_daqiri_pipeline \
//       [--yaml      daqiri/config_pipeline.yaml] \
//       [--bufsize   4096]   (samples; also: 8192, 16384, 32768)
//       [--n-buffers 1000]
//       [--warmup    100]    (buffers to discard before recording)
//       [--out       data/daqiri_pipeline.csv]

#include "signal_gen.h"
#include "metrics.h"
#include "csv_logger.h"
#include "cufft_executor.h"
#include "util_sampler.h"

#include <daqiri/daqiri.h>

#include <arpa/inet.h>
#include <pthread.h>
#include <sched.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include <cuda_runtime.h>

// ── Constants ────────────────────────────────────────────────────────────────

static constexpr int      TX_CPU      = 11;
static constexpr int      RX_CPU      = 9;
static const std::string  SERVER_ADDR = "127.0.0.1";
static constexpr uint16_t SERVER_PORT = 7778;   // different port from M3
static const std::string  CLIENT_ADDR = "127.0.0.1";

// ── Macros ───────────────────────────────────────────────────────────────────

#define CUDA_CHECK(expr)                                                      \
    do {                                                                      \
        cudaError_t _e = (expr);                                              \
        if (_e != cudaSuccess) {                                              \
            std::cerr << "[CUDA] " << cudaGetErrorString(_e)                  \
                      << " at " __FILE__ ":" << __LINE__ << "\n";            \
            std::exit(1);                                                     \
        }                                                                     \
    } while (0)

static void pin_to_core(int core) {
    if (core < 0) return;
    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(core, &cs);
    pthread_setaffinity_np(pthread_self(), sizeof(cs), &cs);
}

// ── TX worker ────────────────────────────────────────────────────────────────

static void tx_worker(
    int                buf_size,
    int                n_to_send,
    std::atomic<bool>& stop,
    std::atomic<bool>& rx_ready,  // set by RX when server conn is up
    std::atomic<int>&  tx_count)
{
    pin_to_core(TX_CPU);

    const int payload_bytes = buf_size * static_cast<int>(sizeof(float));

    SignalConfig sig;
    sig.sample_rate_hz = 1'000'000.0f;
    sig.buffer_size    = buf_size;
    sig.freqs_hz       = {500.0f, 1200.0f, 2500.0f};
    sig.amplitudes     = {1.2f, 0.6f, 0.3f};
    sig.noise_sigma    = 0.02f;   // small noise for realism
    const std::vector<float> signal = make_signal(sig);

    uintptr_t conn_id = 0;
    uint16_t  port = 0, queue = 0;

    // Wait until RX has the server socket ready (handles slow CUDA JIT warm-up)
    while (!stop.load() && !rx_ready.load(std::memory_order_acquire))
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    if (stop.load()) return;

    while (!stop.load() && conn_id == 0) {
        if (daqiri::socket_connect_to_server(
                SERVER_ADDR, SERVER_PORT, CLIENT_ADDR, &conn_id)
            == daqiri::Status::SUCCESS) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (conn_id == 0) return;

    if (daqiri::socket_get_port_queue(conn_id, &port, &queue)
            != daqiri::Status::SUCCESS) {
        std::cerr << "[TX] socket_get_port_queue failed\n";
        stop.store(true);
        return;
    }

    int sent = 0;
    while (!stop.load(std::memory_order_relaxed) && sent < n_to_send) {
        auto* msg = daqiri::create_tx_burst_params();
        daqiri::set_header(msg,
                           static_cast<uint16_t>(port),
                           static_cast<uint16_t>(queue),
                           1, 1);

        if (daqiri::get_tx_packet_burst(msg) != daqiri::Status::SUCCESS) {
            daqiri::free_tx_metadata(msg);
            std::this_thread::sleep_for(std::chrono::microseconds(10));
            continue;
        }

        auto* dst = static_cast<float*>(daqiri::get_packet_ptr(msg, 0));
        std::memcpy(dst, signal.data(), static_cast<size_t>(payload_bytes));
        daqiri::set_packet_lengths(msg, 0, {payload_bytes});
        daqiri::set_connection_id(msg, conn_id);

        if (daqiri::send_tx_burst(msg) == daqiri::Status::SUCCESS) {
            ++sent;
            tx_count.store(sent, std::memory_order_relaxed);
        } else {
            daqiri::free_tx_metadata(msg);
        }
    }
    stop.store(true, std::memory_order_release);
}

// ── RX + pipeline worker ─────────────────────────────────────────────────────
//
// On each received burst:
//   1. Iterate over sub-buffers (socket engine batches multiple payloads)
//   2. Per sub-buffer: H→D copy → cuFFT → record BufferMetrics → CSV log

static void rx_pipeline_worker(
    int                        buf_size,
    int                        n_expected,
    int                        warmup,         // buffers to discard first
    std::atomic<bool>&         stop,
    std::atomic<bool>&         rx_ready,       // set after server conn is ready
    std::atomic<int>&          rx_count,
    std::atomic<uint64_t>&     rx_bytes_total,
    std::vector<BufferMetrics>& metrics_out,   // written by this thread only
    CsvLogger*                 logger,
    UtilSampler*               sampler)        // may be nullptr
{
    pin_to_core(RX_CPU);

    const int     payload_bytes  = buf_size * static_cast<int>(sizeof(float));
    const int     fft_out_bins   = buf_size / 2 + 1;

    // ── CUDA setup ───────────────────────────────────────────────────────────
    float*        d_input  = nullptr;
    cufftComplex* d_output = nullptr;
    CUDA_CHECK(cudaMalloc(&d_input,  static_cast<size_t>(payload_bytes)));
    CUDA_CHECK(cudaMalloc(&d_output,
                          static_cast<size_t>(fft_out_bins) * sizeof(cufftComplex)));

    cudaEvent_t ev_h2d_start, ev_h2d_stop;
    CUDA_CHECK(cudaEventCreate(&ev_h2d_start));
    CUDA_CHECK(cudaEventCreate(&ev_h2d_stop));

    CuFFTExecutor fft(buf_size);

    // ── DAQiri server connection ──────────────────────────────────────────────
    uintptr_t conn_id = 0;
    while (!stop.load() && conn_id == 0) {
        if (daqiri::socket_get_server_conn_id(SERVER_ADDR, SERVER_PORT, &conn_id)
                == daqiri::Status::SUCCESS) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (conn_id == 0) goto cleanup;
    // Signal TX that server is ready — TX will begin connecting now
    rx_ready.store(true, std::memory_order_release);

    // ── Pipeline loop ─────────────────────────────────────────────────────────
    {
        auto last_rx = std::chrono::steady_clock::now();

        while (rx_count.load(std::memory_order_relaxed) < n_expected) {
            // Idle timeout after TX finishes
            if (stop.load(std::memory_order_acquire)) {
                double idle = std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - last_rx).count();
                if (idle > 10.0) {
                    std::cerr << "[RX] 10s idle — stopping\n";
                    break;
                }
            }

            daqiri::BurstParams* burst = nullptr;
            if (daqiri::get_rx_burst(&burst, conn_id, /*is_server=*/true)
                    != daqiri::Status::SUCCESS || burst == nullptr) {
                std::this_thread::sleep_for(std::chrono::microseconds(10));
                continue;
            }

            last_rx = std::chrono::steady_clock::now();
            const uint64_t burst_bytes = daqiri::get_burst_tot_byte(burst);
            const int      n_sub = static_cast<int>(burst_bytes) / payload_bytes;
            const auto*    batch_ptr = static_cast<const float*>(
                daqiri::get_packet_ptr(burst, 0));

            // Process each sub-buffer independently through the CUDA pipeline.
            const int limit = std::min(n_sub, n_expected - rx_count.load());
            for (int s = 0; s < limit; ++s) {
                const float* src = batch_ptr + static_cast<ptrdiff_t>(s) * buf_size;

                const auto t_rx = std::chrono::steady_clock::now();

                // ── H→D transfer (timed via CUDA events) ────────────────────
                CUDA_CHECK(cudaEventRecord(ev_h2d_start));
                CUDA_CHECK(cudaMemcpy(d_input, src,
                                      static_cast<size_t>(payload_bytes),
                                      cudaMemcpyHostToDevice));
                CUDA_CHECK(cudaEventRecord(ev_h2d_stop));
                CUDA_CHECK(cudaEventSynchronize(ev_h2d_stop));

                float h2d_ms = 0.0f;
                CUDA_CHECK(cudaEventElapsedTime(&h2d_ms, ev_h2d_start, ev_h2d_stop));
                const double transfer_us = static_cast<double>(h2d_ms) * 1000.0;

                // ── cuFFT execute ────────────────────────────────────────────
                fft.execute(d_input, d_output);
                const double fft_us = static_cast<double>(fft.last_exec_us());

                const auto t_done = std::chrono::steady_clock::now();
                const double e2e_us = std::chrono::duration<double>(
                    t_done - t_rx).count() * 1e6;

                // ── Compute throughput metrics ───────────────────────────────
                const double total_us = e2e_us > 0.0 ? e2e_us : 1.0;

                // Count absolute buffers processed (warmup + measured)
                const int abs_count = rx_count.load(std::memory_order_relaxed) + s;
                const bool in_warmup = (abs_count < warmup);

                BufferMetrics m;
                m.e2e_latency_us      = e2e_us;
                m.transfer_latency_us = transfer_us;
                m.fft_exec_us         = fft_us;
                m.samples_per_sec     = buf_size  / (total_us * 1e-6);
                m.buffers_per_sec     = 1.0       / (total_us * 1e-6);
                m.mb_per_sec          = static_cast<double>(payload_bytes)
                                        / 1e6 / (total_us * 1e-6);
                m.buffer_size_samples = buf_size;
                m.dropped_buffers     = 0;
                m.cpu_util_pct        = sampler ? sampler->cpu_pct() : 0.0f;
                m.gpu_util_pct        = sampler ? sampler->gpu_pct() : 0.0f;

                if (!in_warmup) {
                    if (logger) logger->log(m);
                    metrics_out.push_back(m);
                }
            }

            // Fallback: if n_sub == 0 (empty burst), still count bytes
            if (n_sub == 0 && burst_bytes > 0) {
                // incomplete last buffer — skip
            }

            rx_count.fetch_add(std::max(n_sub, 1), std::memory_order_relaxed);
            rx_bytes_total.fetch_add(burst_bytes, std::memory_order_relaxed);

            daqiri::free_all_packets_and_burst_rx(burst);
        }
    }

cleanup:
    CUDA_CHECK(cudaEventDestroy(ev_h2d_start));
    CUDA_CHECK(cudaEventDestroy(ev_h2d_stop));
    CUDA_CHECK(cudaFree(d_input));
    CUDA_CHECK(cudaFree(d_output));
}

// ── Helpers: print RunSummary ─────────────────────────────────────────────────

static void print_summary(const RunSummary& s, int buf_size) {
    std::cout << "──────────────────────────────────────────────\n"
              << "  Buffers processed : " << s.n_buffers << "\n"
              << "  Buffer size       : " << buf_size << " samples  ("
              << buf_size * 4 / 1024 << " KB)\n"
              << "  E2E latency\n"
              << "    p50  : " << s.p50_us  << " µs\n"
              << "    p95  : " << s.p95_us  << " µs\n"
              << "    p99  : " << s.p99_us  << " µs\n"
              << "    mean : " << s.mean_us << " µs\n"
              << "    min  : " << s.min_us  << " µs\n"
              << "    max  : " << s.max_us  << " µs\n"
              << "  Jitter (p99-p50)  : " << s.jitter_p99_p50_us << " µs\n"
              << "  Throughput        : " << s.throughput_mb_s << " MB/s\n"
              << "  Dropped buffers   : " << s.total_dropped << "\n"
              << "──────────────────────────────────────────────\n";
}

// ── main ─────────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    std::string yaml_path = "daqiri/config_pipeline.yaml";
    std::string out_path  = "";
    int buf_size  = 4096;
    int n_buffers = 1000;
    int warmup    = 100;   // discard first N buffers (cuFFT JIT + socket warm-up)

    for (int i = 1; i < argc; ++i) {
        if      (!strcmp(argv[i], "--yaml")      && i+1 < argc) yaml_path = argv[++i];
        else if (!strcmp(argv[i], "--bufsize")   && i+1 < argc) buf_size  = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--n-buffers") && i+1 < argc) n_buffers = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--warmup")    && i+1 < argc) warmup    = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--out")       && i+1 < argc) out_path  = argv[++i];
    }

    const int total_send = n_buffers + warmup;  // TX sends warmup + measured

    if (out_path.empty()) {
        out_path = "data/daqiri_pipeline_" + std::to_string(buf_size) + ".csv";
    }

    std::cout << "==== DAQiri M5 — Full Pipeline A (Socket → H→D → cuFFT) ====\n"
              << "  YAML      : " << yaml_path << "\n"
              << "  buf_size  : " << buf_size << " samples  ("
              << buf_size * 4 / 1024 << " KB)\n"
              << "  warmup    : " << warmup << " buffers (discarded)\n"
              << "  n_buffers : " << n_buffers << " (measured)\n"
              << "  CSV out   : " << out_path << "\n\n";

    // ── Create output directory ───────────────────────────────────────────────
    std::error_code ec;
    std::filesystem::create_directories(
        std::filesystem::path(out_path).parent_path(), ec);

    // ── DAQiri init ───────────────────────────────────────────────────────────
    if (daqiri::daqiri_init(yaml_path) != daqiri::Status::SUCCESS) {
        std::cerr << "FAIL: daqiri_init() for " << yaml_path << "\n";
        return 1;
    }
    std::cout << "  daqiri_init()   : OK\n";

    // ── CSV logger ────────────────────────────────────────────────────────────
    CsvLogger logger(out_path);    // ── Warm up CUDA context + cuFFT JIT ────────────────────────────────────
    // cufftPlan1d triggers PTX→cubin compilation on first call for each N.
    // Under Nsight Systems (and at cold start) this can take 10–30 s.
    // Pre-running a full warmup here ensures threads start with a warm JIT cache.
    {
        const int     n_bins    = buf_size / 2 + 1;
        float*        d_tmp_in  = nullptr;
        cufftComplex* d_tmp_out = nullptr;
        CUDA_CHECK(cudaMalloc(&d_tmp_in,
                              static_cast<size_t>(buf_size) * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_tmp_out,
                              static_cast<size_t>(n_bins) * sizeof(cufftComplex)));
        CuFFTExecutor warmup_fft(buf_size);
        warmup_fft.execute(d_tmp_in, d_tmp_out);   // forces PTX compilation
        CUDA_CHECK(cudaFree(d_tmp_in));
        CUDA_CHECK(cudaFree(d_tmp_out));
        std::cout << "  CUDA/cuFFT JIT  : warm (" << warmup_fft.last_exec_us()
                  << " µs first-run)\n";
    }
    // ── Start utilization sampler ─────────────────────────────────────────
    UtilSampler sampler(/*interval_ms=*/10);
    sampler.start();
    std::cout << "  UtilSampler     : started\n";
    // ── Shared state ─────────────────────────────────────────────────────────
    std::atomic<bool>          stop{false};
    std::atomic<bool>          rx_ready{false};  // RX signals when server is up
    std::atomic<int>           tx_count{0};
    std::atomic<int>           rx_count{0};
    std::atomic<uint64_t>      rx_bytes_total{0};
    std::vector<BufferMetrics> all_metrics;
    all_metrics.reserve(static_cast<size_t>(n_buffers));

    const auto t_start = std::chrono::steady_clock::now();

    // ── Launch threads ────────────────────────────────────────────────────────
    std::thread rx_thr(rx_pipeline_worker,
                       buf_size, total_send, warmup,
                       std::ref(stop),
                       std::ref(rx_ready),
                       std::ref(rx_count),
                       std::ref(rx_bytes_total),
                       std::ref(all_metrics),
                       &logger, &sampler);

    // TX starts immediately — it will spin on rx_ready before connecting
    std::thread tx_thr(tx_worker,
                       buf_size, total_send,
                       std::ref(stop),
                       std::ref(rx_ready),
                       std::ref(tx_count));

    tx_thr.join();
    rx_thr.join();

    const double elapsed_s = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t_start).count();

    // ── Print DAQiri engine stats ─────────────────────────────────────────────
    daqiri::print_stats();
    daqiri::shutdown();

    sampler.stop();
    logger.flush();

    // ── Compute and print summary ───────────────────────────────────────────
    const int      received   = rx_count.load();
    const uint64_t rx_bytes   = rx_bytes_total.load();
    const uint64_t exp_bytes  = static_cast<uint64_t>(total_send)
                                * static_cast<uint64_t>(buf_size) * sizeof(float);
    const double   mb_s       = rx_bytes / 1e6 / elapsed_s;

    std::cout << "\n  TX sent    : " << tx_count.load() << " / " << total_send << "\n"
              << "  RX rcvd    : " << received << " buffers\n"
              << "  Bytes RX   : " << rx_bytes << " / " << exp_bytes << "\n"
              << "  Elapsed    : " << elapsed_s << " s\n"
              << "  Total MB/s : " << mb_s << "\n\n";

    if (!all_metrics.empty()) {
        std::vector<double> e2e_lats;
        e2e_lats.reserve(all_metrics.size());
        for (const auto& m : all_metrics) e2e_lats.push_back(m.e2e_latency_us);

        const RunSummary summary = compute_summary(e2e_lats, mb_s, 0);

        // Also report transfer and FFT separately
        std::vector<double> xfer_lats, fft_lats;
        xfer_lats.reserve(all_metrics.size());
        fft_lats.reserve(all_metrics.size());
        for (const auto& m : all_metrics) {
            xfer_lats.push_back(m.transfer_latency_us);
            fft_lats.push_back(m.fft_exec_us);
        }
        std::sort(xfer_lats.begin(), xfer_lats.end());
        std::sort(fft_lats.begin(),  fft_lats.end());
        const int n = static_cast<int>(all_metrics.size());
        auto pct = [&](const std::vector<double>& v, int p) {
            int idx = std::min(static_cast<int>(v.size() * p / 100), n - 1);
            return v[idx];
        };

        std::cout << "==== M5 Pipeline Summary (" << n_buffers << " measured buffers, "
                  << warmup << " warmup discarded) ====\n";
        print_summary(summary, buf_size);

        std::cout << "  H→D transfer latency\n"
                  << "    p50  : " << pct(xfer_lats, 50) << " µs\n"
                  << "    p95  : " << pct(xfer_lats, 95) << " µs\n"
                  << "    p99  : " << pct(xfer_lats, 99) << " µs\n"
                  << "  cuFFT execution time\n"
                  << "    p50  : " << pct(fft_lats, 50) << " µs\n"
                  << "    p95  : " << pct(fft_lats, 95) << " µs\n"
                  << "    p99  : " << pct(fft_lats, 99) << " µs\n\n";

        std::cout << "  CSV written to: " << out_path << "\n";

        // Report mean CPU/GPU utilization over the measured run
        float mean_cpu = 0.0f, mean_gpu = 0.0f;
        for (const auto& m : all_metrics) {
            mean_cpu += m.cpu_util_pct;
            mean_gpu += m.gpu_util_pct;
        }
        const int nm = static_cast<int>(all_metrics.size());
        if (nm > 0) {
            std::cout << "  CPU util (mean) : " << mean_cpu / nm << " %\n"
                      << "  GPU util (mean) : " << mean_gpu / nm << " %\n";
        }
    }

    // Pass if at least 95% of the measured (post-warmup) buffers were processed.
    // We don't check total bytes because some warmup bytes may arrive after
    // rx_count reaches total_send, causing a benign undercount.
    const bool pass = (static_cast<int>(all_metrics.size())
                       >= n_buffers * 95 / 100);
    if (all_metrics.empty()) {
        std::cerr << "FAIL: no metrics captured\n";
    }
    std::cout << "  [note] GPU util=0 is expected: cuFFT bursts (~15 µs) are too\n"
                 "         brief for NVML 1 Hz sampling; use Nsight for GPU profile.\n";
    std::cout << "==== " << (pass ? "M5 PASSED" : "M5 FAILED") << " ====\n";
    return pass ? 0 : 1;
}
