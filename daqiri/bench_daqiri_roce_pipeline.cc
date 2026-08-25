// bench_daqiri_roce_pipeline.cc — TRUE zero-copy pipeline over DAQiri RoCE (RDMA RC).
//
// Sibling of bench_daqiri_pipeline.cc (socket/TCP loopback). Identical metrics and
// methodology; the ONLY variable changed is the transport: RDMA RC instead of the
// TCP-loopback socket engine. RC preserves message boundaries, so a whole payload
// (up to 4 MB) lands in one page-aligned pinned buffer by scatter-gather DMA — no
// fragmentation and a genuine in-place cuFFT (true zero-copy) at every size.
//
//   TX thread = RDMA client : post SEND of the deterministic float32 signal
//   RX thread = RDMA server : pre-post RECEIVEs, poll completions, H->D (or map
//                             in place) -> cuFFT R2C -> record BufferMetrics
//
// Single-process, single-device RC loopback on the assigned RoCE IP (no root,
// no netns). See daqiri/config_roce_pipeline.yaml.
//
// Metrics captured per buffer (same columns as the socket pipeline):
//   e2e_latency_us      — received-buffer-in-hand -> post-FFT (RX-side wall clock)
//   transfer_latency_us — H->D cudaMemcpy (CUDA event); 0 in zero-copy mode
//   fft_exec_us         — cuFFT R2C kernel (CUDA event)
//
// Usage (from repo root):
//   ./build/daqiri/bench_daqiri_roce_pipeline \
//       [--yaml      daqiri/config_roce_pipeline.yaml] \
//       [--bufsize   4096]   (samples; up to 1048576 = 4 MB) \
//       [--n-buffers 1000] [--warmup 100] [--zero-copy] [--pace-us 400] \
//       [--rx-depth 128] [--tx-depth 128] [--out data/daqiri_roce.csv]

#include "signal_gen.h"
#include "metrics.h"
#include "csv_logger.h"
#include "cufft_executor.h"
#include "util_sampler.h"

#include <daqiri/daqiri.h>

#include <pthread.h>
#include <sched.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <cuda_runtime.h>

// ── Constants ────────────────────────────────────────────────────────────────

static constexpr int      TX_CPU      = 11;   // app TX thread (distinct from DAQiri queue cores 16-19)
static constexpr int      RX_CPU      = 9;    // app RX thread
static const std::string  SERVER_ADDR = "192.168.20.1";
static const std::string  CLIENT_ADDR = "192.168.20.1";
static constexpr uint16_t SERVER_PORT = 4096;

// MR names must match config_roce_pipeline.yaml.
static const std::string  SEND_MR = "DATA_TX_GPU_CLIENT";  // client sends from here
static const std::string  RECV_MR = "DATA_RX_GPU_SERVER";  // server receives into here

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

// Resolve a device-usable pointer for a DAQiri RECEIVE buffer without copying.
// DAQiri host_pinned MRs are cudaMallocHost'd (already CUDA-pinned). On the GB10
// (coherent NVLink-C2C, unified addressing) such a buffer is directly reachable
// from the device, so cudaPointerGetAttributes already yields a devicePointer.
// Fallbacks cover plain-malloc'd MRs (register as mapped) and, last resort, the
// unified-addressing case where the host pointer itself is device-usable.
static float* resolve_zc_device_ptr(const float* src, int payload_bytes,
                                    std::vector<void*>& registered) {
    void* host = const_cast<void*>(static_cast<const void*>(src));

    cudaPointerAttributes attr{};
    cudaError_t aerr = cudaPointerGetAttributes(&attr, host);
    if (aerr == cudaSuccess && attr.devicePointer != nullptr)
        return static_cast<float*>(attr.devicePointer);
    (void)cudaGetLastError();

    cudaError_t rerr = cudaHostRegister(host, static_cast<size_t>(payload_bytes),
                                        cudaHostRegisterMapped);
    if (rerr == cudaSuccess) {
        registered.push_back(host);
    } else {
        // Already registered (cudaMallocHost) or cannot register: on unified
        // addressing the host pointer is itself a valid device pointer.
        (void)cudaGetLastError();
        return static_cast<float*>(host);
    }

    float* dptr = nullptr;
    cudaError_t derr = cudaHostGetDevicePointer(
        reinterpret_cast<void**>(&dptr), host, 0);
    if (derr != cudaSuccess || dptr == nullptr) {
        (void)cudaGetLastError();
        return static_cast<float*>(host);
    }
    return dptr;
}

// ── TX worker (RDMA client) ──────────────────────────────────────────────────
//
// Posts SEND work requests carrying the deterministic signal, paced per buffer.
// Drains SEND completions to recycle the transmit window (tx_depth).

static void roce_tx_worker(
    int                buf_size,
    int                n_to_send,
    int                pace_us,
    int                tx_depth,
    std::atomic<bool>& stop,
    std::atomic<bool>& rx_ready,   // set by RX once server is up + receives posted
    std::atomic<int>&  tx_count)
{
    pin_to_core(TX_CPU);

    const int payload_bytes = buf_size * static_cast<int>(sizeof(float));

    SignalConfig sig;
    sig.sample_rate_hz = 1'000'000.0f;
    sig.buffer_size    = buf_size;
    sig.freqs_hz       = {500.0f, 1200.0f, 2500.0f};
    sig.amplitudes     = {1.2f, 0.6f, 0.3f};
    sig.noise_sigma    = 0.02f;
    const std::vector<float> signal = make_signal(sig);

    // Connect FIRST. The server's rdma_get_server_conn_id only returns once this
    // client initiates the RDMA-CM handshake, so TX must not gate on rx_ready
    // before connecting (that would deadlock: server waits for us, we wait for it).
    std::cerr << "[TX] connecting to " << SERVER_ADDR << ":" << SERVER_PORT
              << " (src " << CLIENT_ADDR << ")..." << std::endl;
    uintptr_t conn_id = 0;
    while (!stop.load() && conn_id == 0) {
        if (daqiri::rdma_connect_to_server(SERVER_ADDR, SERVER_PORT, CLIENT_ADDR, &conn_id)
                == daqiri::Status::SUCCESS && conn_id != 0)
            break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (conn_id == 0) { stop.store(true); return; }
    std::cerr << "[TX] connected, conn_id=" << conn_id << std::endl;

    // Now that we're connected, give the server a bounded moment to post its
    // receive window before we start sending (RNR retry covers any residual race).
    auto rr_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!stop.load() && !rx_ready.load(std::memory_order_acquire)
           && std::chrono::steady_clock::now() < rr_deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    if (stop.load()) return;

    int      outstanding_send = 0;
    uint64_t send_wr_id       = 0x1234;
    int      sent             = 0;

    // Drain any available SEND completions to free transmit slots.
    auto drain_sends = [&]() {
        while (true) {
            daqiri::BurstParams* comp = nullptr;
            if (daqiri::get_rx_burst(&comp, conn_id, /*server=*/false)
                    != daqiri::Status::SUCCESS || comp == nullptr)
                break;
            if (daqiri::rdma_get_opcode(comp) == daqiri::RDMAOpCode::SEND && outstanding_send > 0)
                --outstanding_send;
            daqiri::free_tx_burst(comp);
        }
    };

    while (!stop.load(std::memory_order_relaxed) && sent < n_to_send) {
        drain_sends();

        if (outstanding_send >= tx_depth) {
            std::this_thread::sleep_for(std::chrono::microseconds(10));
            continue;
        }

        auto* msg = daqiri::create_tx_burst_params();
        if (msg == nullptr) { std::this_thread::sleep_for(std::chrono::microseconds(10)); continue; }

        if (daqiri::rdma_set_header(msg, daqiri::RDMAOpCode::SEND, conn_id,
                                    /*server=*/false, 1, send_wr_id, SEND_MR)
                != daqiri::Status::SUCCESS) {
            daqiri::free_tx_metadata(msg);
            continue;
        }
        if (!daqiri::is_tx_burst_available(msg)) {
            daqiri::free_tx_metadata(msg);
            std::this_thread::sleep_for(std::chrono::microseconds(10));
            continue;
        }
        if (daqiri::get_tx_packet_burst(msg) != daqiri::Status::SUCCESS) {
            daqiri::free_tx_metadata(msg);
            std::this_thread::sleep_for(std::chrono::microseconds(10));
            continue;
        }

        auto* dst = static_cast<float*>(daqiri::get_packet_ptr(msg, 0));
        std::memcpy(dst, signal.data(), static_cast<size_t>(payload_bytes));
        daqiri::set_packet_lengths(msg, 0, {payload_bytes});

        if (daqiri::send_tx_burst(msg) == daqiri::Status::SUCCESS) {
            ++outstanding_send;
            ++send_wr_id;
            ++sent;
            tx_count.store(sent, std::memory_order_relaxed);
            if (pace_us > 0)
                std::this_thread::sleep_for(std::chrono::microseconds(pace_us));
        } else {
            daqiri::free_tx_burst(msg);
        }
    }

    // Drain remaining SEND completions so the last payloads land cleanly.
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
    while (outstanding_send > 0 && std::chrono::steady_clock::now() < deadline) {
        drain_sends();
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    stop.store(true, std::memory_order_release);
}

// ── RX + pipeline worker (RDMA server) ───────────────────────────────────────
//
// Pre-posts rx_depth RECEIVE work requests, then polls completions. On each
// RECEIVE completion the whole payload is already resident in the posted pinned
// buffer (RC preserves message boundaries) — run H->D (copy) or map in place
// (zero-copy) -> cuFFT -> record metrics -> repost a RECEIVE.

static void roce_rx_pipeline_worker(
    int                        buf_size,
    int                        n_expected,
    int                        warmup,
    bool                       zero_copy,
    bool                       stage_timing,
    int                        rx_depth,
    std::atomic<bool>&         stop,
    std::atomic<bool>&         rx_ready,
    std::atomic<int>&          rx_count,
    std::atomic<uint64_t>&     rx_bytes_total,
    std::vector<BufferMetrics>& metrics_out,
    CsvLogger*                 logger,
    UtilSampler*               sampler)
{
    pin_to_core(RX_CPU);

    const int payload_bytes = buf_size * static_cast<int>(sizeof(float));
    const int fft_out_bins  = buf_size / 2 + 1;

    // ── CUDA setup ───────────────────────────────────────────────────────────
    float*        d_input  = nullptr;
    cufftComplex* d_output = nullptr;
    CUDA_CHECK(cudaMalloc(&d_input,  static_cast<size_t>(payload_bytes)));
    CUDA_CHECK(cudaMalloc(&d_output,
                          static_cast<size_t>(fft_out_bins) * sizeof(cufftComplex)));

    // Zero-copy: map each pinned RECEIVE buffer to a device pointer once and let
    // cuFFT read it in place (NVLink-C2C coherent). RC buffers are page-aligned,
    // so the input is 16-byte aligned and no D2D realign is ever needed.
    std::unordered_map<const void*, float*> zc_dev_cache;
    std::vector<void*> zc_registered;
    bool zc_logged = false;

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

    cudaEvent_t ev_h2d_start, ev_h2d_stop;
    CUDA_CHECK(cudaEventCreate(&ev_h2d_start));
    CUDA_CHECK(cudaEventCreate(&ev_h2d_stop));

    CuFFTExecutor fft(buf_size);

    // ── RDMA server connection ────────────────────────────────────────────────
    std::cerr << "[RX] waiting for client connection on " << SERVER_ADDR << ":"
              << SERVER_PORT << "..." << std::endl;
    uintptr_t conn_id = 0;
    while (!stop.load() && conn_id == 0) {
        if (daqiri::rdma_get_server_conn_id(SERVER_ADDR, SERVER_PORT, &conn_id)
                == daqiri::Status::SUCCESS && conn_id != 0)
            break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (conn_id == 0) goto cleanup;
    std::cerr << "[RX] client connected, conn_id=" << conn_id << std::endl;

    {
        int      outstanding_recv = 0;
        uint64_t recv_wr_id       = 0x2345;

        // Post a single RECEIVE (buffer pulled from the recv MR pool).
        auto post_recv = [&]() -> bool {
            auto* msg = daqiri::create_tx_burst_params();
            if (msg == nullptr) return false;
            if (daqiri::rdma_set_header(msg, daqiri::RDMAOpCode::RECEIVE, conn_id,
                                        /*server=*/true, 1, recv_wr_id, RECV_MR)
                    != daqiri::Status::SUCCESS) {
                daqiri::free_tx_metadata(msg);
                return false;
            }
            if (!daqiri::is_tx_burst_available(msg)) {
                daqiri::free_tx_metadata(msg);
                return false;
            }
            if (daqiri::get_tx_packet_burst(msg) != daqiri::Status::SUCCESS) {
                daqiri::free_tx_metadata(msg);
                return false;
            }
            if (daqiri::set_packet_lengths(msg, 0, {payload_bytes}) != daqiri::Status::SUCCESS) {
                daqiri::free_tx_burst(msg);
                return false;
            }
            if (daqiri::send_tx_burst(msg) != daqiri::Status::SUCCESS) {
                daqiri::free_tx_burst(msg);
                return false;
            }
            ++outstanding_recv;
            ++recv_wr_id;
            return true;
        };

        // Pre-post the receive window before signalling TX to start.
        for (int i = 0; i < rx_depth; ++i) {
            if (!post_recv()) break;
        }
        std::cerr << "[RX] posted " << outstanding_recv << " receives, entering poll loop"
                  << std::endl;
        rx_ready.store(true, std::memory_order_release);

        auto last_rx = std::chrono::steady_clock::now();

        while (rx_count.load(std::memory_order_relaxed) < n_expected) {
            if (stop.load(std::memory_order_acquire)) {
                double idle = std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - last_rx).count();
                if (idle > 10.0) { std::cerr << "[RX] 10s idle — stopping\n"; break; }
            }

            daqiri::BurstParams* completion = nullptr;
            if (daqiri::get_rx_burst(&completion, conn_id, /*server=*/true)
                    != daqiri::Status::SUCCESS || completion == nullptr) {
                std::this_thread::sleep_for(std::chrono::microseconds(10));
                continue;
            }

            if (daqiri::rdma_get_opcode(completion) != daqiri::RDMAOpCode::RECEIVE) {
                daqiri::free_tx_burst(completion);
                continue;
            }

            last_rx = std::chrono::steady_clock::now();
            const float* src = static_cast<const float*>(daqiri::get_packet_ptr(completion, 0));

            const auto t_rx = std::chrono::steady_clock::now();
            double transfer_us = 0.0;
            const bool st = stage_timing;
            std::chrono::steady_clock::time_point ts_a, ts_b, ts_c, ts_d;

            if (zero_copy) {
                if (st) ts_a = std::chrono::steady_clock::now();
                // Map the pinned RECEIVE buffer to a device pointer, FFT in place.
                auto it = zc_dev_cache.find(src);
                if (it == zc_dev_cache.end()) {
                    float* dptr = resolve_zc_device_ptr(src, payload_bytes, zc_registered);
                    it = zc_dev_cache.emplace(src, dptr).first;
                }
                float* zc_dptr = it->second;
                const bool needs_realign =
                    (reinterpret_cast<uintptr_t>(zc_dptr) & 15) != 0;
                if (!zc_logged) {
                    zc_logged = true;
                    std::cerr << "[daqiri-roce][zero-copy] host="
                              << static_cast<const void*>(src)
                              << " dev=" << static_cast<void*>(zc_dptr)
                              << " (align16="
                              << (reinterpret_cast<uintptr_t>(zc_dptr) & 15) << ") "
                              << (needs_realign ? "D2D-realign" : "in-place")
                              << std::endl;
                }
                if (st) ts_b = std::chrono::steady_clock::now();
                if (needs_realign) {
                    CUDA_CHECK(cudaMemcpyAsync(d_input, zc_dptr,
                                               static_cast<size_t>(payload_bytes),
                                               cudaMemcpyDeviceToDevice));
                    if (st) ts_c = std::chrono::steady_clock::now();
                    fft.execute(d_input, d_output);
                } else {
                    if (st) ts_c = std::chrono::steady_clock::now();
                    fft.execute(zc_dptr, d_output);
                }
                if (st) {
                    ts_d = std::chrono::steady_clock::now();
                    auto us = [](const std::chrono::steady_clock::time_point& a,
                                 const std::chrono::steady_clock::time_point& b) {
                        return std::chrono::duration<double>(b - a).count() * 1e6;
                    };
                    st_lookup_us.push_back(us(ts_a, ts_b));
                    st_realign_us.push_back(us(ts_b, ts_c));
                    st_fftcall_us.push_back(us(ts_c, ts_d));
                }
            } else {
                CUDA_CHECK(cudaEventRecord(ev_h2d_start));
                CUDA_CHECK(cudaMemcpy(d_input, src,
                                      static_cast<size_t>(payload_bytes),
                                      cudaMemcpyHostToDevice));
                CUDA_CHECK(cudaEventRecord(ev_h2d_stop));
                CUDA_CHECK(cudaEventSynchronize(ev_h2d_stop));
                float h2d_ms = 0.0f;
                CUDA_CHECK(cudaEventElapsedTime(&h2d_ms, ev_h2d_start, ev_h2d_stop));
                transfer_us = static_cast<double>(h2d_ms) * 1000.0;
                fft.execute(d_input, d_output);
            }

            const double fft_us  = static_cast<double>(fft.last_exec_us());
            const auto   t_done  = std::chrono::steady_clock::now();
            const double e2e_us  = std::chrono::duration<double>(t_done - t_rx).count() * 1e6;
            const double total_us = e2e_us > 0.0 ? e2e_us : 1.0;

            const int  abs_count = rx_count.load(std::memory_order_relaxed);
            const bool in_warmup = (abs_count < warmup);

            BufferMetrics m;
            m.e2e_latency_us      = e2e_us;
            m.transfer_latency_us = transfer_us;
            m.fft_exec_us         = fft_us;
            m.samples_per_sec     = buf_size  / (total_us * 1e-6);
            m.buffers_per_sec     = 1.0       / (total_us * 1e-6);
            m.mb_per_sec          = static_cast<double>(payload_bytes) / 1e6 / (total_us * 1e-6);
            m.buffer_size_samples = buf_size;
            m.dropped_buffers     = 0;
            m.cpu_util_pct        = sampler ? sampler->cpu_pct() : 0.0f;
            m.gpu_util_pct        = sampler ? sampler->gpu_pct() : 0.0f;
            if (!in_warmup) {
                if (logger) logger->log(m);
                metrics_out.push_back(m);
            }

            rx_count.fetch_add(1, std::memory_order_relaxed);
            rx_bytes_total.fetch_add(static_cast<uint64_t>(payload_bytes),
                                     std::memory_order_relaxed);

            daqiri::free_tx_burst(completion);
            post_recv();   // refill the receive window
        }
    }

cleanup:
    if (stage_timing) {
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
        std::cout << "\n---- Stage timers (same intervals as bench_grpc_server) ----\n";
        stage(st_lookup_us,  "register+lookup");
        stage(st_realign_us, "realign enqueue");
        stage(st_fftcall_us, "fft call (wall)");
        std::cout << "  note: 'fft call (wall)' minus the CSV fft_exec_us is"
                     " launch + sync overhead.\n"
                  << "------------------------------------------------\n";
    }
    for (void* p : zc_registered) {
        cudaError_t uerr = cudaHostUnregister(p);
        if (uerr != cudaSuccess && uerr != cudaErrorHostMemoryNotRegistered)
            (void)cudaGetLastError();
    }
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
    std::cerr << "[MAIN] start" << std::endl;
    std::cout << std::unitbuf;   // flush stdout on every << so progress isn't lost
    std::string yaml_path = "daqiri/config_roce_pipeline.yaml";
    std::string out_path  = "";
    int  buf_size  = 4096;
    int  n_buffers = 1000;
    int  warmup    = 100;
    bool zero_copy = false;
    bool stage_timing = false;
    int  pace_us   = 0;
    int  rx_depth  = 128;
    int  tx_depth  = 128;

    for (int i = 1; i < argc; ++i) {
        if      (!strcmp(argv[i], "--yaml")      && i+1 < argc) yaml_path = argv[++i];
        else if (!strcmp(argv[i], "--bufsize")   && i+1 < argc) buf_size  = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--n-buffers") && i+1 < argc) n_buffers = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--warmup")    && i+1 < argc) warmup    = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--zero-copy"))               zero_copy = true;
        else if (!strcmp(argv[i], "--stage-timing"))            stage_timing = true;
        else if (!strcmp(argv[i], "--pace-us")   && i+1 < argc) pace_us   = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rx-depth")  && i+1 < argc) rx_depth  = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--tx-depth")  && i+1 < argc) tx_depth  = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--out")       && i+1 < argc) out_path  = argv[++i];
    }

    const int total_send = n_buffers + warmup;

    if (out_path.empty())
        out_path = "data/daqiri_roce_" + std::to_string(buf_size) + ".csv";

    std::cout << "==== DAQiri RoCE — TRUE zero-copy Pipeline (RDMA RC → cuFFT) ====\n"
              << "  YAML      : " << yaml_path << "\n"
              << "  buf_size  : " << buf_size << " samples  ("
              << buf_size * 4 / 1024 << " KB)\n"
              << "  warmup    : " << warmup << " buffers (discarded)\n"
              << "  n_buffers : " << n_buffers << " (measured)\n"
              << "  transport : DAQiri RoCE (RDMA RC)   "
              << (zero_copy ? "[ZERO-COPY]" : "[copy]") << "\n"
              << "  rx/tx dep : " << rx_depth << " / " << tx_depth << "\n"
              << "  CSV out   : " << out_path << "\n\n";

    std::error_code ec;
    std::filesystem::create_directories(
        std::filesystem::path(out_path).parent_path(), ec);

    std::cerr << "[MAIN] calling daqiri_init(" << yaml_path << ")" << std::endl;
    if (daqiri::daqiri_init(yaml_path) != daqiri::Status::SUCCESS) {
        std::cerr << "FAIL: daqiri_init() for " << yaml_path << "\n";
        return 1;
    }
    std::cerr << "[MAIN] daqiri_init returned OK" << std::endl;
    std::cout << "  daqiri_init()   : OK\n";

    CsvLogger logger(out_path);

    // Warm the cuFFT JIT so the first measured buffer isn't a 10-30 s outlier.
    {
        const int     n_bins    = buf_size / 2 + 1;
        float*        d_tmp_in  = nullptr;
        cufftComplex* d_tmp_out = nullptr;
        CUDA_CHECK(cudaMalloc(&d_tmp_in,  static_cast<size_t>(buf_size) * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_tmp_out, static_cast<size_t>(n_bins) * sizeof(cufftComplex)));
        CuFFTExecutor warmup_fft(buf_size);
        warmup_fft.execute(d_tmp_in, d_tmp_out);
        CUDA_CHECK(cudaFree(d_tmp_in));
        CUDA_CHECK(cudaFree(d_tmp_out));
        std::cout << "  CUDA/cuFFT JIT  : warm (" << warmup_fft.last_exec_us()
                  << " µs first-run)\n";
    }

    UtilSampler sampler(/*interval_ms=*/10);
    sampler.start();
    std::cout << "  UtilSampler     : started\n";

    std::atomic<bool>          stop{false};
    std::atomic<bool>          rx_ready{false};
    std::atomic<int>           tx_count{0};
    std::atomic<int>           rx_count{0};
    std::atomic<uint64_t>      rx_bytes_total{0};
    std::vector<BufferMetrics> all_metrics;
    all_metrics.reserve(static_cast<size_t>(n_buffers));

    const auto t_start = std::chrono::steady_clock::now();

    std::cerr << "[MAIN] launching RX + TX threads" << std::endl;
    std::thread rx_thr(roce_rx_pipeline_worker,
                       buf_size, total_send, warmup, zero_copy, stage_timing,
                       rx_depth,
                       std::ref(stop), std::ref(rx_ready),
                       std::ref(rx_count), std::ref(rx_bytes_total),
                       std::ref(all_metrics), &logger, &sampler);

    std::thread tx_thr(roce_tx_worker,
                       buf_size, total_send, pace_us, tx_depth,
                       std::ref(stop), std::ref(rx_ready), std::ref(tx_count));

    tx_thr.join();
    rx_thr.join();

    const double elapsed_s = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t_start).count();

    daqiri::print_stats();
    daqiri::shutdown();

    sampler.stop();
    logger.flush();

    const int      received  = rx_count.load();
    const uint64_t rx_bytes  = rx_bytes_total.load();
    const uint64_t exp_bytes = static_cast<uint64_t>(total_send)
                               * static_cast<uint64_t>(buf_size) * sizeof(float);
    const double   mb_s      = rx_bytes / 1e6 / elapsed_s;

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

        std::cout << "==== RoCE Pipeline Summary (" << n_buffers << " measured buffers, "
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

    const bool pass = (static_cast<int>(all_metrics.size()) >= n_buffers * 95 / 100);
    if (all_metrics.empty()) std::cerr << "FAIL: no metrics captured\n";
    std::cout << "==== " << (pass ? "RoCE PIPELINE PASSED" : "RoCE PIPELINE FAILED")
              << " ====\n";
    std::cout.flush();
    std::cerr.flush();
    // daqiri keeps a background RDMA-CM thread running; its static teardown can
    // hang on normal process exit. The CSV and all results are already flushed,
    // so bypass global destructors and terminate immediately and deterministically.
    _exit(pass ? 0 : 1);
}
