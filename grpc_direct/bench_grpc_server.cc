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
                           const std::string& out_path, bool one_shot,
                           bool zero_copy, bool verify,
                           bool stage_timing = false,
                           bool zc_h2d = false, bool zc_align = false)
        : buf_size_(buf_size), n_buffers_(n_buffers), warmup_(warmup),
          out_path_(out_path), one_shot_(one_shot), zero_copy_(zero_copy),
          verify_(verify), stage_timing_(stage_timing), zc_h2d_(zc_h2d),
          zc_align_(zc_align), server_(nullptr) {}

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

        // Zero-copy (Route 1) state.  We cudaHostRegister the host sample
        // buffer and map it to a device pointer so cuFFT reads it in place over
        // the GH200 coherent link.  Level 1 reuses one BufferRequest per stream,
        // so the backing store is a single stable pointer.  Level 2 (--zc-parse)
        // binds the samples span straight into the grpc-direct shmem loan, whose
        // address rotates through the receive ring, so we cache one device
        // pointer per distinct slot and reuse it thereafter.
        std::unordered_map<const void*, float*> zc_dev_cache;
        std::vector<void*> zc_registered;     // ptrs we actually cudaHostRegister'd
        float*        zc_dptr      = nullptr;  // device ptr for the current buf
        int           zc_reg_count = 0;        // distinct registrations made
        bool          zc_logged    = false;    // one-shot span-capture log
        bool          verified     = false;    // one-shot spectral correctness

        // ── Phase-0 residual attribution ────────────────────────────────────
        // The 4 MB sweep shows gRPC's (e2e - fft_exec) residual growing with
        // payload size (8.1 us at 16 KB -> 81.5 us at 4 MB) while DAQiri's
        // stays flat at ~4.9 us.  These counters and stage timers attribute
        // that residual.  If zc_reg_count ~= the measured buffer count then the
        // cache is missing on every message and we re-pin the whole payload
        // each time, which is the leading hypothesis.
        long long     zc_cache_hits = 0;   // zc_dev_cache lookups that hit
        long long     realign_count = 0;   // messages that needed the D2D copy

        // How this session feeds cuFFT.  Decided once, on the first message,
        // then reused.  kProbe means "not decided yet".
        enum ZcMode { kProbe = 0, kInPlace = 1, kRealign = 2 };
        ZcMode        zc_mode = kProbe;
        std::vector<double> st_reg_us;     // cache lookup + cudaHostRegister
        std::vector<double> st_realign_us; // D2D realign enqueue
        std::vector<double> st_fftcall_us; // wall time of fft->execute()

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
            std::cout << "[shmem] session opened  buf_size=" << buf_size_
                      << (zero_copy_ ? "  [ZERO-COPY]" : "  [copy]") << "\n";

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
        } else if (req->samples()._zcptr_ != nullptr) {
            // Level-2 zero-copy: the samples span points straight into the
            // grpc-direct shmem loan buffer — no protobuf parse copy happened.
            src    = req->samples()._zcptr_;
            n_samp = static_cast<int>(req->samples()._zcsz_);
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
            double xfer_us = 0.0;
            // Phase-0 stage timers.  Off by default so baseline runs are
            // unperturbed; each steady_clock read is ~20 ns, negligible against
            // the 8-81 us residual we are trying to attribute.
            const bool st = stage_timing_;
            std::chrono::steady_clock::time_point ts_a, ts_b, ts_c, ts_d;
            if (zero_copy_) {
                if (st) ts_a = std::chrono::steady_clock::now();
                // ── Route 1: coherent zero-copy (GH200) ──────────────────────
                // Map the host sample buffer to a device pointer and let cuFFT
                // read it in place over NVLink-C2C — no std::memcpy, no
                // cudaMemcpy; the h_staging intermediate is bypassed entirely.
                // Level 1 sees one stable backing store; Level 2 (--zc-parse)
                // points into the shmem loan, whose address rotates through the
                // ring, so we cache one device pointer per distinct slot.
                auto it = s.zc_dev_cache.find(src);
                if (it == s.zc_dev_cache.end()) {
                    void* reg = const_cast<void*>(static_cast<const void*>(src));
                    // The Level-2 spans rotate through the grpc-direct shmem
                    // receive ring; adjacent slots share OS pages, so the 64 KB
                    // registration of a later slot can overlap one already
                    // mapped by an earlier slot.  cudaHostRegister then returns
                    // cudaErrorHostMemoryAlreadyRegistered — that is benign: the
                    // range is already mapped, so cudaHostGetDevicePointer still
                    // resolves a valid device address.  Only track the pointers
                    // we truly registered so teardown unmaps them exactly once.
                    cudaError_t rerr = cudaHostRegister(reg, copy_bytes,
                                                        cudaHostRegisterMapped);
                    if (rerr == cudaSuccess) {
                        s.zc_registered.push_back(reg);
                    } else if (rerr == cudaErrorHostMemoryAlreadyRegistered) {
                        (void)cudaGetLastError();  // clear the sticky error
                    } else {
                        CUDA_CHECK(rerr);
                    }
                    float* dptr = nullptr;
                    CUDA_CHECK(cudaHostGetDevicePointer(
                        reinterpret_cast<void**>(&dptr), reg, 0));
                    it = s.zc_dev_cache.emplace(src, dptr).first;
                    ++s.zc_reg_count;
                } else {
                    ++s.zc_cache_hits;
                }
                s.zc_dptr = it->second;
                if (st) ts_b = std::chrono::steady_clock::now();

                // ── Decide once how to feed cuFFT ────────────────────────────
                // Phase 0 measured the protobuf backing store at align16=8, so
                // the old hard-coded `(dptr & 15) != 0` rule sent EVERY message
                // down the realign copy.  That copy cost ~77 µs at 4 MB (hidden
                // inside the FFT's cudaEventSynchronize) and accounted for the
                // whole gap against DAQiri.
                //
                // --zc-align (E2) stops guessing: if the pointer is not 16-byte
                // aligned we ask cuFFT directly whether it will accept it.  If
                // it does, the realign copy disappears entirely.
                if (s.zc_mode == ShmemSession::kProbe) {
                    const uintptr_t a = reinterpret_cast<uintptr_t>(s.zc_dptr);
                    const char* why;
                    if ((a & 15) == 0) {
                        s.zc_mode = ShmemSession::kInPlace;  why = "16B aligned";
                    } else if (zc_align_ &&
                               s.fft->try_execute(s.zc_dptr, s.d_output)) {
                        s.zc_mode = ShmemSession::kInPlace;
                        why = "probe: cuFFT accepts this alignment";
                    } else {
                        s.zc_mode = ShmemSession::kRealign;
                        why = zc_align_ ? "probe: cuFFT rejected it"
                                        : "not 16B aligned";
                    }
                    std::cerr << "[shmem][zero-copy] "
                              << (req->samples()._zcptr_
                                      ? "L2 span into shmem loan"
                                      : "L1 reused proto store")
                              << " host=" << static_cast<const void*>(src)
                              << " (align16=" << (reinterpret_cast<uintptr_t>(src) & 15)
                              << ") dev=" << static_cast<void*>(s.zc_dptr)
                              << " (align16=" << (a & 15) << ") -> "
                              << (s.zc_mode == ShmemSession::kInPlace
                                      ? "in-place"
                                      : (zc_h2d_ ? "H2D-realign" : "D2D-realign"))
                              << "  [" << why << "]" << std::endl;
                    s.zc_logged = true;
                }

                if (s.zc_mode == ShmemSession::kRealign) {
                    ++s.realign_count;
                    if (zc_h2d_) {
                        // E1: copy from the page-locked HOST pointer over the
                        // H2D DMA path instead of D2D from the mapped device
                        // alias.  Same bytes, potentially a much better engine:
                        // Phase 0 measured the D2D path at only ~52 GB/s.
                        CUDA_CHECK(cudaMemcpyAsync(s.d_input, src, copy_bytes,
                                                   cudaMemcpyHostToDevice));
                    } else {
                        CUDA_CHECK(cudaMemcpyAsync(s.d_input, s.zc_dptr, copy_bytes,
                                                   cudaMemcpyDeviceToDevice));
                    }
                    if (st) ts_c = std::chrono::steady_clock::now();
                    s.fft->execute(s.d_input, s.d_output);
                } else {
                    if (st) ts_c = std::chrono::steady_clock::now();
                    s.fft->execute(s.zc_dptr, s.d_output);
                }
                if (st) {
                    ts_d = std::chrono::steady_clock::now();
                    auto us = [](const std::chrono::steady_clock::time_point& a,
                                 const std::chrono::steady_clock::time_point& b) {
                        return std::chrono::duration<double>(b - a).count() * 1e6;
                    };
                    s.st_reg_us.push_back(us(ts_a, ts_b));
                    s.st_realign_us.push_back(us(ts_b, ts_c));
                    s.st_fftcall_us.push_back(us(ts_c, ts_d));
                }
                // No CPU copy and no H->D transfer occur on this path; any
                // realignment is a device-internal copy, so transfer latency is
                // reported as 0.
                xfer_us = 0.0;
            } else {
                // ── Copy path: proto → pinned staging → device ───────────────
                std::memcpy(s.h_staging, src, copy_bytes);
                CUDA_CHECK(cudaEventRecord(s.ev_h2d_start));
                CUDA_CHECK(cudaMemcpy(s.d_input, s.h_staging, copy_bytes,
                                      cudaMemcpyHostToDevice));
                CUDA_CHECK(cudaEventRecord(s.ev_h2d_stop));
                CUDA_CHECK(cudaEventSynchronize(s.ev_h2d_stop));
                float h2d_ms = 0.f;
                CUDA_CHECK(cudaEventElapsedTime(&h2d_ms, s.ev_h2d_start,
                                                s.ev_h2d_stop));
                s.fft->execute(s.d_input, s.d_output);
                xfer_us = static_cast<double>(h2d_ms) * 1000.0;
            }
            const double fft_us  = s.fft->last_exec_us();
            const auto   t_done  = std::chrono::steady_clock::now();
            const double e2e_us  = std::chrono::duration<double>(t_done - t_recv).count() * 1e6;

            // ── One-shot spectral correctness check ───────────────────────────
            // detect_peaks copies d_output to host (not hot-path safe), so run
            // it exactly once on the first measured buffer.  Proves the FFT of
            // the (zero-copy or copied) input recovers the known input tones.
            if (verify_ && !s.verified && s.buf_idx >= warmup_) {
                s.verified = true;
                const auto peaks = s.fft->detect_peaks(s.d_output, 3,
                                                       /*sample_rate_hz=*/1'000'000.0f);
                std::cout << "[verify] " << (zero_copy_ ? "ZERO-COPY" : "copy")
                          << " top-3 peaks (expect ~500/1200/2500 Hz): ";
                for (const auto& pk : peaks)
                    std::cout << pk.first << " Hz (" << pk.second << ")  ";
                std::cout << std::endl;
            }
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
                << "  Transport mode    : "
                << (zero_copy_ ? "shmem ZERO-COPY (in-place, no H->D copy)"
                              : "shmem copy (staging + cudaMemcpy)") << "\n"
                << "  CSV written to    : " << s.csv_path << "\n"
                << "==== M8 PASSED ====\n";
        } else {
            std::cerr << "[shmem] no measured buffers\n";
            summary->set_buffers_received(0);
        }

        // ── Phase-0 residual attribution report ──────────────────────────────
        // zc_reg_count alone decides the leading hypothesis: if it tracks the
        // message count, the device-pointer cache misses every message and we
        // re-pin the entire payload each time.  If it stays small, the residual
        // is somewhere else and the stage timers say where.
        if (zero_copy_) {
            const long long msgs = s.zc_cache_hits + s.zc_reg_count;
            std::cout << "\n---- Phase 0: zero-copy residual attribution ----\n"
                      << "  messages seen     : " << msgs << "\n"
                      << "  cudaHostRegister  : " << s.zc_reg_count
                      << "   (cache hits: " << s.zc_cache_hits << ")\n"
                      << "  dev-ptr cache size: " << s.zc_dev_cache.size() << "\n"
                      << "  feed mode         : "
                      << (s.zc_mode == ShmemSession::kInPlace ? "in-place (no copy)"
                          : s.zc_mode == ShmemSession::kRealign
                              ? (zc_h2d_ ? "realign via H2D" : "realign via D2D")
                              : "never decided")
                      << "\n"
                      << "  realigns          : " << s.realign_count << "\n";
            if (msgs > 0) {
                const double miss_pct =
                    100.0 * static_cast<double>(s.zc_reg_count) / static_cast<double>(msgs);
                std::cout << "  register rate     : " << miss_pct << " % of messages\n"
                          << "  VERDICT           : "
                          << (miss_pct > 50.0
                                  ? "CONFIRMED - re-pinning the payload per message"
                                  : "NOT the dominant cost - look at the stage timers")
                          << "\n";
            }
            auto stage = [](std::vector<double> v, const char* name) {
                if (v.empty()) return;
                std::sort(v.begin(), v.end());
                auto q = [&](int p) {
                    return v[static_cast<size_t>(
                        std::min<int>(static_cast<int>(v.size()) * p / 100,
                                      static_cast<int>(v.size()) - 1))];
                };
                std::cout << "  " << name << " p50/p99 : " << q(50) << " / "
                          << q(99) << " us  (n=" << v.size() << ")\n";
            };
            stage(s.st_reg_us,     "register+lookup");
            stage(s.st_realign_us, "realign enqueue");
            stage(s.st_fftcall_us, "fft call (wall)");
            std::cout << "  note: 'fft call (wall)' minus the CSV fft_exec_us is"
                         " launch + sync overhead.\n"
                      << "------------------------------------------------\n";
        }

        for (void* p : s.zc_registered) {
            cudaError_t uerr = cudaHostUnregister(p);
            if (uerr != cudaSuccess && uerr != cudaErrorHostMemoryNotRegistered)
                (void)cudaGetLastError();  // benign on overlapping ranges
        }
        s.zc_registered.clear();
        s.zc_dev_cache.clear();
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
    bool        zero_copy_;
    bool        verify_;
    bool        stage_timing_;
    bool        zc_h2d_;
    bool        zc_align_;
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
    bool zero_copy = false;                // Route 1 coherent zero-copy (shmem)
    bool zc_parse  = false;                // Level 2: samples span into loan
    bool verify    = false;                // one-shot spectral correctness check
    bool stage_timing = false;             // Phase 0: attribute the ZC residual
    bool zc_h2d       = false;             // E1: realign via H2D, not D2D
    bool zc_align     = false;             // E2: probe cuFFT instead of assuming 16B
    std::string transport  = "standard";  // "standard" | "shmem" | "tcp"

    for (int i = 1; i < argc; ++i) {
        if      (!strcmp(argv[i], "--port")      && i+1 < argc) server_address = std::string("0.0.0.0:") + argv[++i];
        else if (!strcmp(argv[i], "--bufsize")   && i+1 < argc) buf_size  = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--n-buffers") && i+1 < argc) n_buffers = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--warmup")    && i+1 < argc) warmup    = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--out")       && i+1 < argc) out_path  = argv[++i];
        else if (!strcmp(argv[i], "--one-shot"))                 one_shot  = true;
        else if (!strcmp(argv[i], "--transport") && i+1 < argc) transport = argv[++i];
        else if (!strcmp(argv[i], "--zero-copy"))                zero_copy = true;
        else if (!strcmp(argv[i], "--zc-parse"))               { zero_copy = true; zc_parse = true; }
        else if (!strcmp(argv[i], "--verify"))                   verify = true;
        else if (!strcmp(argv[i], "--stage-timing"))             stage_timing = true;
        else if (!strcmp(argv[i], "--zc-h2d"))                    zc_h2d = true;
        else if (!strcmp(argv[i], "--zc-align"))                  zc_align = true;
    }

    const bool use_grpc_direct = (transport != "standard");

    if (zero_copy && !use_grpc_direct) {
        std::cerr << "[warn] --zero-copy is only implemented for the shmem/"
                     "grpc-direct path; ignoring for standard transport.\n";
        zero_copy = false;
        zc_parse  = false;
    }

    std::cout << "==== Pipeline B Server (gRPC Direct → H→D → cuFFT) ====\n"
              << "  address   : " << server_address << "\n"
              << "  buf_size  : " << buf_size << " samples  ("
              << buf_size * 4 / 1024 << " KB)\n"
              << "  n_buffers : " << n_buffers << "  warmup: " << warmup << "\n"
              << "  transport : " << transport
              << (zero_copy ? "   [ZERO-COPY]" : "   [copy]") << "\n";

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
    PipelineFFTServiceImpl service(buf_size, n_buffers, warmup, out_path,
                                   one_shot, zero_copy, verify, stage_timing,
                                   zc_h2d, zc_align);

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

        // Level 2 (--zc-parse): override the generated streaming handler with
        // one that keeps the samples array zero-copy.  The generated handler
        // does a full BufferRequest::ParseFromArray, which copies the float
        // payload out of the shmem loan into a RepeatedField.  Here we instead
        // use DirectBufferRequest::ParseGDZCArrays, which parses only the scalar
        // fields and binds a Span<const float> (_zcptr_/_zcsz_) straight into
        // the loan buffer, so the samples are never copied on the CPU before
        // cuFFT reads them.  Registering the same method name overwrites the
        // generated entry in the router's dispatch map.  The loan buffer stays
        // valid for the duration of this synchronous handler call, so cuFFT
        // (which we synchronise before returning) reads it safely; we pass a
        // null BufferHandle because no cross-call retention is required.
        if (zc_parse) {
            PipelineFFTServiceImpl* svc = &service;
            router_ptr->RegisterStreaming(
                "/pipeline_fft.PipelineFFTService/StreamBuffers",
                [svc]() -> AutoDirectRouter::StreamHandler {
                    auto state = std::make_shared<::pipeline_fft::PipelineSummary>();
                    auto dreq  = std::make_shared<::pipeline_fft::DirectBufferRequest>();
                    return [svc, state, dreq](const uint8_t* req, int reqLen,
                                              GrpcDirectActiveRequest* loanHandle) -> int {
                        if (reqLen > 0)
                            dreq->ParseGDZCArrays(req, static_cast<size_t>(reqLen),
                                                  nullptr);
                        ::grpc::ServerContext ctx;
                        auto status = svc->StreamBuffersPerMessage(
                            &ctx, &dreq->inner, state.get());
                        if (!status.ok()) return 0;
                        size_t protoSize = state->ByteSizeLong();
                        uint8_t* protoBuf = nullptr;
                        if (protoSize > 0) {
                            protoBuf = new uint8_t[protoSize];
                            state->SerializeToArray(protoBuf,
                                                    static_cast<int>(protoSize));
                        }
                        int rc = grpc_direct_server_send_status(
                            loanHandle, GRPC_DIRECT_STATUS_OK, nullptr,
                            protoBuf, protoSize);
                        if (protoBuf) delete[] protoBuf;
                        return rc == 0 ? 1 : -1;
                    };
                });
            std::cout << "  [zero-copy L2] custom GDZC parse handler installed "
                         "(samples span into loan; no parse copy)\n";
        }

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
