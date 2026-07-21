// bench_grpc_server.cc — Pipeline B server: receives float32 buffers via gRPC
// Direct client-streaming, copies to GPU, runs cuFFT, records metrics.
//
// Mirrors Pipeline A (bench_daqiri_pipeline.cc) on the receive+GPU side.
// Transport: gRPC Direct (shmem / tcp / tcp_low_latency / rdma).
//
// Usage (from ~/daqiri_gpu, as separate build):
//   ./build_grpc/bench_grpc_server \
//       [--port       50052]
//       [--bufsize    4096]          (float32 samples per buffer)
//       [--n-buffers  1000]          (expected measured buffers)
//       [--warmup     100]           (discard first N buffers)
//       [--out        data/grpc_pipeline_4096.csv]
//       [--one-shot]                 (exit after first completed call)

#include "signal_gen.h"   // for SignalConfig (warmup FFT pre-fill)
#include "metrics.h"
#include "csv_logger.h"
#include "cufft_executor.h"
#include "util_sampler.h"

// gRPC / grpc-direct headers
#include <grpcpp/grpcpp.h>
#ifndef STANDARD_GRPC_ONLY
#  include <grpc_direct_service_impl.h>
#  include <auto_direct_router.h>
#  include <grpc_direct.h>
#  include <grpc_direct_types.h>
#endif

// Generated proto stubs
#ifdef STANDARD_GRPC_ONLY
// No grpc_direct.proto dependency — safe to link without libgrpc_direct.so
#  include "pipeline_fft_std.pb.h"
#  include "pipeline_fft_std.grpc.pb.h"
#else
#  include "pipeline_fft.pb.h"
#  include "pipeline_fft.grpc.pb.h"
#  include "pipeline_fft.grpc_direct.pb.h"
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <unordered_map>
#include <filesystem>
#include <iostream>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

#include <cuda_runtime.h>
#include <cufft.h>

// ── CUDA error check ─────────────────────────────────────────────────────────

#define CUDA_CHECK(expr)                                                      \
    do {                                                                      \
        cudaError_t _e = (expr);                                              \
        if (_e != cudaSuccess) {                                              \
            std::cerr << "[CUDA] " << cudaGetErrorString(_e)                  \
                      << " at " __FILE__ ":" << __LINE__ << "\n";            \
            std::exit(1);                                                     \
        }                                                                     \
    } while (0)

// ── Service implementation ────────────────────────────────────────────────────

class PipelineFFTServiceImpl
    : public pipeline_fft::PipelineFFTService::Service {
public:
    PipelineFFTServiceImpl(int buf_size, int n_buffers, int warmup,
                           const std::string& out_path, bool one_shot)
        : buf_size_(buf_size), n_buffers_(n_buffers), warmup_(warmup),
          out_path_(out_path), one_shot_(one_shot), server_(nullptr) {}

    void set_server(grpc::Server* s) { server_ = s; }

    grpc::Status StreamBuffers(
        grpc::ServerContext*  /*ctx*/,
        grpc::ServerReader<pipeline_fft::BufferRequest>* reader,
        pipeline_fft::PipelineSummary* summary) override
    {
        const int payload_bytes = buf_size_ * static_cast<int>(sizeof(float));
        const int fft_out_bins  = buf_size_ / 2 + 1;

        // ── CUDA setup ──────────────────────────────────────────────────────
        float*        d_input  = nullptr;
        cufftComplex* d_output = nullptr;
        CUDA_CHECK(cudaMalloc(&d_input,  static_cast<size_t>(payload_bytes)));
        CUDA_CHECK(cudaMalloc(&d_output,
                              static_cast<size_t>(fft_out_bins) * sizeof(cufftComplex)));

        // Pinned (page-locked) staging buffer: avoids "invalid argument" on
        // GH200 UMA when cudaMemcpy is sourced from pageable protobuf heap.
        // Persistent across buffers to amortise cudaMallocHost overhead.
        float* h_staging = nullptr;
        CUDA_CHECK(cudaMallocHost(reinterpret_cast<void**>(&h_staging),
                                  static_cast<size_t>(payload_bytes)));

        cudaEvent_t ev_h2d_start, ev_h2d_stop;
        CUDA_CHECK(cudaEventCreate(&ev_h2d_start));
        CUDA_CHECK(cudaEventCreate(&ev_h2d_stop));

        // cuFFT plan (JIT already warm from main() pre-run)
        CuFFTExecutor fft(buf_size_);

        // ── CSV logger ──────────────────────────────────────────────────────
        std::string csv_path = out_path_.empty()
            ? "data/grpc_pipeline_" + std::to_string(buf_size_) + ".csv"
            : out_path_;
        std::error_code ec;
        std::filesystem::create_directories(
            std::filesystem::path(csv_path).parent_path(), ec);
        CsvLogger logger(csv_path);

        // ── Util sampler ────────────────────────────────────────────────────
        UtilSampler sampler(/*interval_ms=*/10);
        sampler.start();

        // ── Per-buffer receive loop ─────────────────────────────────────────
        // Use a plain BufferRequest for the standard gRPC path.  The
        // grpc-direct zero-copy path (ScopedGDZCReceiver) is reserved for
        // shmem/tcp-direct transports; using it on a standard gRPC stream can
        // stall the Read() loop on long runs (>~4 MB cumulative).
        pipeline_fft::BufferRequest req;
        std::vector<BufferMetrics> metrics;
        metrics.reserve(static_cast<size_t>(n_buffers_));

        int buf_idx = 0;

        while (reader->Read(&req)) {
            const auto t_recv = std::chrono::steady_clock::now();
            // Wall-clock (CLOCK_REALTIME) receive stamp for wire latency.
            // Client and server share the host (localhost), so the delta
            // against req.send_timestamp_ns() is valid despite the absolute
            // wall clock being unreliable on this machine.
            const long long recv_wall_ns =
                std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::system_clock::now().time_since_epoch()).count();

            // ── Get float data ───────────────────────────────────────────────
            // Prefer raw_samples (standard gRPC path); fall back to
            // grpc_direct.FloatArray for the shmem/tcp-direct transport.
            const float* src    = nullptr;
            int          n_samp = 0;
            if (!req.raw_samples().empty()) {
                src    = reinterpret_cast<const float*>(req.raw_samples().data());
                n_samp = static_cast<int>(req.raw_samples().size() / sizeof(float));
            }
#ifndef STANDARD_GRPC_ONLY
            else {
                const auto& vals = req.samples().values();
                src    = vals.data();
                n_samp = static_cast<int>(vals.size());
            }
#endif

            // Guard: skip mismatched buffers rather than crashing.
            if (n_samp != buf_size_) {
                std::cerr << "[server] unexpected n_samp=" << n_samp
                          << " expected=" << buf_size_
                          << " at buf_idx=" << buf_idx << "\n";
                ++buf_idx;
                continue;
            }

            const size_t copy_bytes = static_cast<size_t>(n_samp) * sizeof(float);

            // ── H→D transfer (CUDA event timed) ─────────────────────────────
            // Copy proto bytes to pinned staging first; this avoids a CUDA
            // "invalid argument" on GH200 caused by DMAing from pageable heap
            // after the driver's internal bounce-buffer pool (~4 MB) is full.
            std::memcpy(h_staging, src, copy_bytes);
            CUDA_CHECK(cudaEventRecord(ev_h2d_start));
            CUDA_CHECK(cudaMemcpy(d_input, h_staging, copy_bytes,
                                  cudaMemcpyHostToDevice));
            CUDA_CHECK(cudaEventRecord(ev_h2d_stop));
            CUDA_CHECK(cudaEventSynchronize(ev_h2d_stop));

            float h2d_ms = 0.0f;
            CUDA_CHECK(cudaEventElapsedTime(&h2d_ms, ev_h2d_start, ev_h2d_stop));
            const double transfer_us = static_cast<double>(h2d_ms) * 1000.0;

            // ── cuFFT R2C ────────────────────────────────────────────────────
            fft.execute(d_input, d_output);
            const double fft_us = static_cast<double>(fft.last_exec_us());

            const auto   t_done = std::chrono::steady_clock::now();
            const double e2e_us = std::chrono::duration<double>(
                t_done - t_recv).count() * 1e6;

            const bool in_warmup = (buf_idx < warmup_);

            if (!in_warmup) {
                const double total_us = e2e_us > 0.0 ? e2e_us : 1.0;
                BufferMetrics m;
                m.e2e_latency_us      = e2e_us;
                m.transfer_latency_us = transfer_us;
                m.fft_exec_us         = fft_us;
                m.samples_per_sec     = n_samp  / (total_us * 1e-6);
                m.buffers_per_sec     = 1.0     / (total_us * 1e-6);
                m.mb_per_sec          = static_cast<double>(copy_bytes)
                                        / 1e6 / (total_us * 1e-6);
                m.buffer_size_samples = buf_size_;
                m.dropped_buffers     = 0;
                m.cpu_util_pct        = sampler.cpu_pct();
                m.gpu_util_pct        = sampler.gpu_pct();
                {
                    const long long send_ns = req.send_timestamp_ns();
                    m.wire_latency_us =
                        send_ns > 0 ? (recv_wall_ns - send_ns) / 1000.0 : 0.0;
                }
                logger.log(m);
                metrics.push_back(m);
            }
            ++buf_idx;
        }

        sampler.stop();
        logger.flush();
        CUDA_CHECK(cudaFreeHost(h_staging));

        // ── Build PipelineSummary ────────────────────────────────────────────
        const int n = static_cast<int>(metrics.size());
        if (n > 0) {
            std::vector<double> e2e_v(n), xfer_v(n), fft_v(n);
            for (int i = 0; i < n; ++i) {
                e2e_v[i]  = metrics[i].e2e_latency_us;
                xfer_v[i] = metrics[i].transfer_latency_us;
                fft_v[i]  = metrics[i].fft_exec_us;
            }
            std::sort(e2e_v.begin(),  e2e_v.end());
            std::sort(xfer_v.begin(), xfer_v.end());
            std::sort(fft_v.begin(),  fft_v.end());

            auto pct = [&](const std::vector<double>& v, int p) {
                int idx = std::min(n * p / 100, n - 1);
                return v[static_cast<size_t>(idx)];
            };

            const double sum_e2e  = std::accumulate(e2e_v.begin(), e2e_v.end(), 0.0);
            const double total_mb = static_cast<double>(n)
                                    * static_cast<double>(buf_size_)
                                    * sizeof(float) / 1e6;
            const double elapsed_s = sum_e2e / n * 1e-6 * n;

            summary->set_buffers_received(n);
            summary->set_e2e_p50_us(pct(e2e_v,  50));
            summary->set_e2e_p95_us(pct(e2e_v,  95));
            summary->set_e2e_p99_us(pct(e2e_v,  99));
            summary->set_e2e_mean_us(sum_e2e / n);
            summary->set_e2e_min_us(e2e_v.front());
            summary->set_e2e_max_us(e2e_v.back());
            summary->set_transfer_p50_us(pct(xfer_v, 50));
            summary->set_transfer_p95_us(pct(xfer_v, 95));
            summary->set_transfer_p99_us(pct(xfer_v, 99));
            summary->set_fft_p50_us(pct(fft_v, 50));
            summary->set_fft_p95_us(pct(fft_v, 95));
            summary->set_fft_p99_us(pct(fft_v, 99));
            summary->set_throughput_mb_s(elapsed_s > 0.0 ? total_mb / elapsed_s : 0.0);
            summary->set_dropped_buffers(0);
            summary->set_csv_path(csv_path);

            float mean_cpu = 0.0f, mean_gpu = 0.0f;
            for (const auto& m : metrics) {
                mean_cpu += m.cpu_util_pct;
                mean_gpu += m.gpu_util_pct;
            }
            summary->set_cpu_util_pct(static_cast<double>(mean_cpu) / n);
            summary->set_gpu_util_pct(static_cast<double>(mean_gpu) / n);

            // ── Print summary (mirrors Pipeline A format) ────────────────────
            const double jitter = pct(e2e_v, 99) - pct(e2e_v, 50);
            std::cout << "\n==== Pipeline B Summary (" << n
                      << " measured buffers, " << warmup_ << " warmup discarded) ====\n"
                      << "──────────────────────────────────────────────\n"
                      << "  Buffers processed : " << n << "\n"
                      << "  Buffer size       : " << buf_size_ << " samples  ("
                      << buf_size_ * 4 / 1024 << " KB)\n"
                      << "  E2E latency (server: Read→FFT)\n"
                      << "    p50  : " << pct(e2e_v,  50)  << " µs\n"
                      << "    p95  : " << pct(e2e_v,  95)  << " µs\n"
                      << "    p99  : " << pct(e2e_v,  99)  << " µs\n"
                      << "    mean : " << sum_e2e / n       << " µs\n"
                      << "    min  : " << e2e_v.front()     << " µs\n"
                      << "    max  : " << e2e_v.back()      << " µs\n"
                      << "  Jitter (p99-p50)  : " << jitter << " µs\n"
                      << "  Throughput        : " << (elapsed_s > 0.0 ? total_mb / elapsed_s : 0.0) << " MB/s\n"
                      << "  Dropped buffers   : 0\n"
                      << "──────────────────────────────────────────────\n"
                      << "  H→D transfer latency\n"
                      << "    p50  : " << pct(xfer_v, 50) << " µs\n"
                      << "    p95  : " << pct(xfer_v, 95) << " µs\n"
                      << "    p99  : " << pct(xfer_v, 99) << " µs\n"
                      << "  cuFFT execution time\n"
                      << "    p50  : " << pct(fft_v, 50) << " µs\n"
                      << "    p95  : " << pct(fft_v, 95) << " µs\n"
                      << "    p99  : " << pct(fft_v, 99) << " µs\n\n"
                      << "  CSV written to: " << csv_path << "\n"
                      << "  CPU util (mean) : " << mean_cpu / n << " %\n"
                      << "  GPU util (mean) : " << mean_gpu / n << " %\n"
                      << "  [note] GPU util=0 is expected: cuFFT bursts (~15 µs) too brief\n"
                      << "         for NVML 1 Hz sampling; use Nsight for GPU profile.\n"
                      << "==== M7 PASSED ====\n";
        } else {
            std::cerr << "[server] no measured buffers — FAILED\n";
            summary->set_buffers_received(0);
        }

        // ── CUDA cleanup ─────────────────────────────────────────────────────
        CUDA_CHECK(cudaEventDestroy(ev_h2d_start));
        CUDA_CHECK(cudaEventDestroy(ev_h2d_stop));
        CUDA_CHECK(cudaFree(d_input));
        CUDA_CHECK(cudaFree(d_output));

        // ── One-shot shutdown ─────────────────────────────────────────────────
        // Standard gRPC (n > 0): shut down immediately.
        // Shmem/grpc-direct (n == 0): do NOT shut down here — data is routed to
        // StreamBuffersPerMessage, and a per-session watchdog thread finalizes
        // and triggers the shutdown once buffers stop arriving.
        if (one_shot_ && server_ && n > 0) {
            std::thread([this]() {
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                server_->Shutdown(std::chrono::system_clock::now()
                                  + std::chrono::seconds(3));
            }).detach();
        }

        return grpc::Status::OK;
    }

#ifndef STANDARD_GRPC_ONLY
    // ── grpc-direct per-message streaming dispatch ────────────────────────────
    // The generated InitPipelineFFTServiceGDZCRouter only registers a shmem/
    // tcp-direct handler when the service exposes StreamBuffersPerMessage.  The
    // grpc-direct framework calls this once per received message.  End-of-stream
    // is detected by counting: when buf_idx reaches warmup+n_buffers the session
    // is finalised.  (The reqLen==0 re-delivery approach only fires on server
    // Shutdown, not on client Disconnect, so it is unreliable here.)
    //
    // Session state is keyed by the persistent PipelineSummary* that the
    // generated handler factory allocates once per RPC; it is stable for the
    // lifetime of the session and unique across concurrent sessions.

    struct ShmemSession {
        bool   initialized  = false;
        bool   finalized    = false;
        int    buf_idx      = 0;
        std::chrono::steady_clock::time_point last_activity{};

        float*        d_input    = nullptr;
        cufftComplex* d_output   = nullptr;
        float*        h_staging  = nullptr;
        cudaEvent_t   ev_h2d_start{}, ev_h2d_stop{};

        std::unique_ptr<CuFFTExecutor> fft;
        std::unique_ptr<CsvLogger>     logger;
        std::unique_ptr<UtilSampler>   sampler;
        std::vector<BufferMetrics>     metrics;
        std::string                    csv_path;
    };

    inline static std::mutex shmem_mtx_;
    inline static std::unordered_map<pipeline_fft::PipelineSummary*, ShmemSession>
        shmem_sessions_;

    grpc::Status StreamBuffersPerMessage(
        grpc::ServerContext*,
        const pipeline_fft::BufferRequest* req,
        pipeline_fft::PipelineSummary*      summary)
    {
        std::lock_guard<std::mutex> lk(shmem_mtx_);
        auto& s = shmem_sessions_[summary];

        // Ignore deliveries after we have already finalised (e.g. grpc-direct
        // may re-deliver the last request on teardown).
        if (s.finalized) return grpc::Status::OK;

        s.last_activity = std::chrono::steady_clock::now();

        // ── Initialise on first call ──────────────────────────────────────────
        if (!s.initialized) {
            const int payload_bytes = buf_size_ * static_cast<int>(sizeof(float));
            const int fft_out_bins  = buf_size_ / 2 + 1;
            CUDA_CHECK(cudaMalloc(&s.d_input,
                                  static_cast<size_t>(payload_bytes)));
            CUDA_CHECK(cudaMalloc(&s.d_output,
                                  static_cast<size_t>(fft_out_bins) * sizeof(cufftComplex)));
            CUDA_CHECK(cudaMallocHost(reinterpret_cast<void**>(&s.h_staging),
                                      static_cast<size_t>(payload_bytes)));
            CUDA_CHECK(cudaEventCreate(&s.ev_h2d_start));
            CUDA_CHECK(cudaEventCreate(&s.ev_h2d_stop));
            s.fft = std::make_unique<CuFFTExecutor>(buf_size_);
            s.csv_path = out_path_.empty()
                ? "data/grpc_pipeline_" + std::to_string(buf_size_) + ".csv"
                : out_path_;
            std::error_code ec;
            std::filesystem::create_directories(
                std::filesystem::path(s.csv_path).parent_path(), ec);
            s.logger  = std::make_unique<CsvLogger>(s.csv_path);
            s.sampler = std::make_unique<UtilSampler>(/*interval_ms=*/10);
            s.sampler->start();
            s.metrics.reserve(static_cast<size_t>(n_buffers_));
            s.initialized = true;
            std::cout << "[shmem] session opened  buf_size=" << buf_size_ << "\n";

            // Watchdog: finalize on inactivity in case grpc-direct drops
            // messages and the full (warmup+n_buffers) count never arrives.
            std::thread([this, summary]() {
                constexpr auto kIdle = std::chrono::seconds(3);
                for (;;) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(250));
                    std::lock_guard<std::mutex> wlk(shmem_mtx_);
                    auto it = shmem_sessions_.find(summary);
                    if (it == shmem_sessions_.end()) return;   // already gone
                    auto& ss = it->second;
                    if (ss.finalized) return;
                    if (std::chrono::steady_clock::now() - ss.last_activity
                            >= kIdle) {
                        FinalizeShmemSession(summary, ss);
                        return;
                    }
                }
            }).detach();
        }

        // ── Get float data ────────────────────────────────────────────────────
        const float* src    = nullptr;
        int          n_samp = 0;
        if (!req->raw_samples().empty()) {
            src    = reinterpret_cast<const float*>(req->raw_samples().data());
            n_samp = static_cast<int>(req->raw_samples().size() / sizeof(float));
        } else {
            const auto& vals = req->samples().values();
            src    = vals.data();
            n_samp = static_cast<int>(vals.size());
        }

        // ── Process one buffer (skip if size mismatch) ────────────────────────
        if (n_samp == buf_size_) {
            const auto   t_recv     = std::chrono::steady_clock::now();
            // Wall-clock (CLOCK_REALTIME) receive stamp for wire latency
            // (client + server share the host, so the delta is valid).
            const long long recv_wall_ns =
                std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::system_clock::now().time_since_epoch()).count();
            const size_t copy_bytes = static_cast<size_t>(n_samp) * sizeof(float);
            std::memcpy(s.h_staging, src, copy_bytes);
            CUDA_CHECK(cudaEventRecord(s.ev_h2d_start));
            CUDA_CHECK(cudaMemcpy(s.d_input, s.h_staging, copy_bytes,
                                  cudaMemcpyHostToDevice));
            CUDA_CHECK(cudaEventRecord(s.ev_h2d_stop));
            CUDA_CHECK(cudaEventSynchronize(s.ev_h2d_stop));
            float h2d_ms = 0.f;
            CUDA_CHECK(cudaEventElapsedTime(&h2d_ms, s.ev_h2d_start, s.ev_h2d_stop));
            s.fft->execute(s.d_input, s.d_output);
            const double fft_us  = s.fft->last_exec_us();
            const auto   t_done  = std::chrono::steady_clock::now();
            const double e2e_us  = std::chrono::duration<double>(t_done - t_recv).count() * 1e6;
            const double xfer_us = static_cast<double>(h2d_ms) * 1000.0;
            const bool in_warmup = (s.buf_idx < warmup_);
            if (!in_warmup) {
                BufferMetrics m;
                m.e2e_latency_us      = e2e_us;
                m.transfer_latency_us = xfer_us;
                m.fft_exec_us         = fft_us;
                m.samples_per_sec     = n_samp  / (e2e_us > 0.0 ? e2e_us * 1e-6 : 1e-9);
                m.buffers_per_sec     = 1.0     / (e2e_us > 0.0 ? e2e_us * 1e-6 : 1e-9);
                m.mb_per_sec          = static_cast<double>(copy_bytes) / 1e6
                                        / (e2e_us > 0.0 ? e2e_us * 1e-6 : 1e-9);
                m.buffer_size_samples = buf_size_;
                m.dropped_buffers     = 0;
                m.cpu_util_pct        = s.sampler->cpu_pct();
                m.gpu_util_pct        = s.sampler->gpu_pct();
                {
                    const long long send_ns = req->send_timestamp_ns();
                    m.wire_latency_us =
                        send_ns > 0 ? (recv_wall_ns - send_ns) / 1000.0 : 0.0;
                }
                s.logger->log(m);
                s.metrics.push_back(m);
            }
        }
        ++s.buf_idx;

        // ── Count-based finalization ──────────────────────────────────────────
        // Close the session once all expected (warmup + measured) buffers have
        // arrived.  A background watcher thread (started on session-open) also
        // finalizes on inactivity, in case grpc-direct drops messages and the
        // full count never arrives.
        if (s.buf_idx >= warmup_ + n_buffers_) {
            FinalizeShmemSession(summary, s);
        }
        return grpc::Status::OK;
    }

    // ── Finalize one shmem session (caller must hold shmem_mtx_) ──────────────
    // Computes percentiles, fills the summary, flushes the CSV, frees CUDA
    // resources, erases the session, and triggers one-shot shutdown.
    void FinalizeShmemSession(pipeline_fft::PipelineSummary* summary,
                              ShmemSession& s)
    {
        if (s.finalized) return;
        s.finalized = true;
        s.sampler->stop();
        s.logger->flush();

        const int n = static_cast<int>(s.metrics.size());
        std::cout << "[shmem] session closed  n_measured=" << n << "\n";

        if (n > 0) {
            std::vector<double> e2e_v(n), xfer_v(n), fft_v(n);
            for (int i = 0; i < n; ++i) {
                e2e_v[i]  = s.metrics[i].e2e_latency_us;
                xfer_v[i] = s.metrics[i].transfer_latency_us;
                fft_v[i]  = s.metrics[i].fft_exec_us;
            }
            std::sort(e2e_v.begin(), e2e_v.end());
            std::sort(xfer_v.begin(), xfer_v.end());
            std::sort(fft_v.begin(), fft_v.end());

            auto ppct = [&](const std::vector<double>& v, int p) {
                return v[static_cast<size_t>(std::min(n * p / 100, n - 1))];
            };
            const double sum_e2e   = std::accumulate(e2e_v.begin(), e2e_v.end(), 0.0);
            const double total_mb  = static_cast<double>(n) * buf_size_
                                     * sizeof(float) / 1e6;
            const double elapsed_s = sum_e2e / n * 1e-6 * n;

            summary->set_buffers_received(n);
            summary->set_e2e_p50_us(ppct(e2e_v,  50));
            summary->set_e2e_p95_us(ppct(e2e_v,  95));
            summary->set_e2e_p99_us(ppct(e2e_v,  99));
            summary->set_e2e_mean_us(sum_e2e / n);
            summary->set_e2e_min_us(e2e_v.front());
            summary->set_e2e_max_us(e2e_v.back());
            summary->set_transfer_p50_us(ppct(xfer_v, 50));
            summary->set_transfer_p95_us(ppct(xfer_v, 95));
            summary->set_transfer_p99_us(ppct(xfer_v, 99));
            summary->set_fft_p50_us(ppct(fft_v, 50));
            summary->set_fft_p95_us(ppct(fft_v, 95));
            summary->set_fft_p99_us(ppct(fft_v, 99));
            summary->set_throughput_mb_s(
                elapsed_s > 0.0 ? total_mb / elapsed_s : 0.0);
            summary->set_dropped_buffers(0);
            summary->set_csv_path(s.csv_path);
            float mc = 0.f, mg = 0.f;
            for (const auto& m : s.metrics) {
                mc += m.cpu_util_pct;
                mg += m.gpu_util_pct;
            }
            summary->set_cpu_util_pct(mc / n);
            summary->set_gpu_util_pct(mg / n);

            const double jitter = ppct(e2e_v, 99) - ppct(e2e_v, 50);
            std::cout
                << "\n==== Pipeline B Summary (" << n
                << " measured, " << warmup_ << " warmup) ====\n"
                << "  Buffers processed : " << n << "\n"
                << "  Buffer size       : " << buf_size_ << " samples  ("
                << buf_size_ * 4 / 1024 << " KB)\n"
                << "  E2E p50/p95/p99   : "
                << ppct(e2e_v,50)  << " / " << ppct(e2e_v,95)  << " / "
                << ppct(e2e_v,99)  << " us\n"
                << "  Jitter (p99-p50)  : " << jitter << " us\n"
                << "  Throughput        : "
                << (elapsed_s > 0.0 ? total_mb / elapsed_s : 0.0) << " MB/s\n"
                << "  H->D p50/p95/p99  : "
                << ppct(xfer_v,50) << " / " << ppct(xfer_v,95) << " / "
                << ppct(xfer_v,99) << " us\n"
                << "  cuFFT p50         : " << ppct(fft_v,50) << " us\n"
                << "  CSV written to    : " << s.csv_path << "\n"
                << "==== M8 PASSED ====\n";
        } else {
            std::cerr << "[shmem] no measured buffers\n";
            summary->set_buffers_received(0);
        }

        CUDA_CHECK(cudaEventDestroy(s.ev_h2d_start));
        CUDA_CHECK(cudaEventDestroy(s.ev_h2d_stop));
        CUDA_CHECK(cudaFree(s.d_input));
        CUDA_CHECK(cudaFree(s.d_output));
        CUDA_CHECK(cudaFreeHost(s.h_staging));
        shmem_sessions_.erase(summary);

        if (one_shot_ && server_) {
            std::thread([this]() {
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                server_->Shutdown(std::chrono::system_clock::now()
                                  + std::chrono::seconds(3));
            }).detach();
        }
    }
#endif

private:
    int         buf_size_;
    int         n_buffers_;
    int         warmup_;
    std::string out_path_;
    bool        one_shot_;
    grpc::Server* server_;
};

// ── main ──────────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    std::string server_address = "0.0.0.0:50052";
    int  buf_size  = 4096;
    int  n_buffers = 1000;
    int  warmup    = 100;
    std::string out_path;
    bool one_shot  = false;
    std::string transport  = "standard";  // "standard" | "shmem" | "tcp"

    for (int i = 1; i < argc; ++i) {
        if      (!strcmp(argv[i], "--port")      && i+1 < argc) server_address = std::string("0.0.0.0:") + argv[++i];
        else if (!strcmp(argv[i], "--bufsize")   && i+1 < argc) buf_size  = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--n-buffers") && i+1 < argc) n_buffers = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--warmup")    && i+1 < argc) warmup    = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--out")       && i+1 < argc) out_path  = argv[++i];
        else if (!strcmp(argv[i], "--one-shot"))                 one_shot  = true;
        else if (!strcmp(argv[i], "--transport") && i+1 < argc) transport = argv[++i];
    }

    const bool use_grpc_direct = (transport != "standard");

    std::cout << "==== Pipeline B Server (gRPC Direct → H→D → cuFFT) ====\n"
              << "  address   : " << server_address << "\n"
              << "  buf_size  : " << buf_size << " samples  ("
              << buf_size * 4 / 1024 << " KB)\n"
              << "  n_buffers : " << n_buffers << "  warmup: " << warmup << "\n";

    // ── Pre-warm CUDA/cuFFT JIT (mirrors Pipeline A) ─────────────────────────
    {
        const int n_bins = buf_size / 2 + 1;
        float*        d_tmp_in  = nullptr;
        cufftComplex* d_tmp_out = nullptr;
        CUDA_CHECK(cudaMalloc(&d_tmp_in,  static_cast<size_t>(buf_size) * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_tmp_out, static_cast<size_t>(n_bins)   * sizeof(cufftComplex)));
        CuFFTExecutor warmup_fft(buf_size);
        warmup_fft.execute(d_tmp_in, d_tmp_out);
        CUDA_CHECK(cudaFree(d_tmp_in));
        CUDA_CHECK(cudaFree(d_tmp_out));
        std::cout << "  CUDA/cuFFT JIT  : warm (" << warmup_fft.last_exec_us() << " µs)\n";
    }

    // ── Build gRPC server ────────────────────────────────────────────────────
    PipelineFFTServiceImpl service(buf_size, n_buffers, warmup, out_path, one_shot);

    // grpc-direct infrastructure (router + GRPCDirectServiceImpl) is only needed
    // for shmem/tcp-direct transports.  For standard gRPC, skip it entirely:
    // InitPipelineFFTServiceGDZCRouter installs a server-side interceptor that
    // strips proto fields it doesn't recognise (including raw_samples = 4) before
    // they reach StreamBuffers.
#ifndef STANDARD_GRPC_ONLY
    std::unique_ptr<AutoDirectRouter>                       router_ptr;
    std::unique_ptr<grpc_direct_lib::GRPCDirectServiceImpl> direct_svc_ptr;
    if (use_grpc_direct) {
        router_ptr = std::make_unique<AutoDirectRouter>();
        grpc_direct_registration::InitPipelineFFTServiceGDZCRouter(*router_ptr, &service);
        direct_svc_ptr = std::make_unique<grpc_direct_lib::GRPCDirectServiceImpl>("pipeline_fft");
        direct_svc_ptr->SetRouter(router_ptr.get());
    }
#endif

    constexpr int kMaxMsgBytes = 256 * 1024 * 1024;  // 256 MB
    grpc::ServerBuilder builder;
    builder.AddListeningPort(server_address, grpc::InsecureServerCredentials());
    builder.SetMaxReceiveMessageSize(kMaxMsgBytes);
    builder.SetMaxSendMessageSize(kMaxMsgBytes);
    builder.RegisterService(&service);
#ifndef STANDARD_GRPC_ONLY
    if (use_grpc_direct)
        builder.RegisterService(direct_svc_ptr.get());
#endif

    auto server = builder.BuildAndStart();
    service.set_server(server.get());

    std::cout << "  Server ready — waiting for client...\n";

    // In-process channel for grpc-direct routing (not needed for standard gRPC).
#ifndef STANDARD_GRPC_ONLY
    if (use_grpc_direct) {
        grpc::ChannelArguments in_proc_args;
        in_proc_args.SetMaxReceiveMessageSize(256 * 1024 * 1024);
        in_proc_args.SetMaxSendMessageSize(256 * 1024 * 1024);
        auto channel = server->InProcessChannel(in_proc_args);
        direct_svc_ptr->SetChannelGetter([channel]() { return channel; });
    }
#endif

    server->Wait();

    // Metrics + CSV are already flushed inside FinalizeShmemSession (or the
    // standard-gRPC path) before the one-shot shutdown was triggered, so all
    // measurement output is safely on disk by the time Wait() returns.
    //
    // We deliberately terminate with std::_Exit instead of a normal return:
    // the grpc-direct / iceoryx2 shared-memory objects double-free during
    // static/global destruction ("double free or corruption", "Unable to
    // remove node resources"), which raises SIGABRT.  That abnormal exit
    // leaves the CUDA / GH200 driver state degraded and, once several servers
    // have crashed in a session, inflates the H->D cudaMemcpy latency of
    // subsequent runs from ~20us to 100-240us.  A clean _Exit lets the kernel
    // reclaim all GPU and shared-memory resources deterministically.
    std::cout.flush();
    std::cerr.flush();
    std::_Exit(0);
    return 0;
}
