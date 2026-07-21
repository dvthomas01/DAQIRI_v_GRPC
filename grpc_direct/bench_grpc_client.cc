// bench_grpc_client.cc — Pipeline B client: generates synthetic float32 signal
// and streams it to the gRPC Direct server via client-streaming RPC.
//
// Mirrors Pipeline A TX worker (bench_daqiri_pipeline.cc tx_worker).
//
// Usage (from ~/daqiri_gpu, as separate build):
//   ./build_grpc/bench_grpc_client \
//       [--server    localhost:50052]
//       [--transport shmem|tcp|tcp_low_latency|standard]   default: shmem
//       [--bufsize   4096]
//       [--n-buffers 1000]
//       [--warmup    100]

#include "signal_gen.h"

#include <grpcpp/grpcpp.h>
#ifndef STANDARD_GRPC_ONLY
#  include <sharedmem_client_interceptor.h>   // grpc-direct interceptor
#  include <grpc_direct_types.h>
#endif

#ifdef STANDARD_GRPC_ONLY
#  include "pipeline_fft_std.pb.h"
#  include "pipeline_fft_std.grpc.pb.h"
#else
#  include "pipeline_fft.pb.h"
#  include "pipeline_fft.grpc.pb.h"
#  include "pipeline_fft.grpc_direct.pb.h"
#endif

#include <chrono>
#include <thread>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

// ── Transport helper ──────────────────────────────────────────────────────────

#ifndef STANDARD_GRPC_ONLY
static grpc_direct::TransportType parse_transport(const char* s) {
    if (!strcmp(s, "tcp"))              return grpc_direct::TCP;
    if (!strcmp(s, "tcp_low_latency"))  return grpc_direct::TCP_LOW_LATENCY;
    if (!strcmp(s, "rdma"))             return grpc_direct::RDMA;
    if (!strcmp(s, "rdma_low_latency")) return grpc_direct::RDMA_LOW_LATENCY;
    return grpc_direct::SHARED_MEMORY;
}
#endif

static bool is_standard_grpc(const char* s) {
    return !strcmp(s, "standard") || !strcmp(s, "none");
}

// ── main ──────────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    std::string server       = "localhost:50052";
    const char* transport_str = "shmem";
    int buf_size    = 4096;
    int n_buffers   = 1000;
    int warmup      = 100;
    int pace_us     = 400;   // per-buffer send pacing for shmem (µs); 0 = unpaced

    for (int i = 1; i < argc; ++i) {
        if      (!strcmp(argv[i], "--server")     && i+1 < argc) server       = argv[++i];
        else if (!strcmp(argv[i], "--transport")  && i+1 < argc) transport_str = argv[++i];
        else if (!strcmp(argv[i], "--bufsize")    && i+1 < argc) buf_size     = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--n-buffers")  && i+1 < argc) n_buffers    = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--warmup")     && i+1 < argc) warmup       = std::atoi(argv[++i]);
        else if (!strcmp(argv[i], "--pace-us")    && i+1 < argc) pace_us      = std::atoi(argv[++i]);
    }

    const int total_send = n_buffers + warmup;

    std::cout << "==== Pipeline B Client (gRPC Direct) ====\n"
              << "  server     : " << server << "\n"
              << "  transport  : " << transport_str << "\n"
              << "  buf_size   : " << buf_size << " samples  ("
              << buf_size * 4 / 1024 << " KB)\n"
              << "  total send : " << total_send
              << "  (" << warmup << " warmup + " << n_buffers << " measured)\n";

    // ── Generate synthetic signal (same as Pipeline A) ────────────────────────
    SignalConfig sig;
    sig.sample_rate_hz = 1'000'000.0f;
    sig.buffer_size    = buf_size;
    sig.freqs_hz       = {500.0f, 1200.0f, 2500.0f};
    sig.amplitudes     = {1.2f, 0.6f, 0.3f};
    sig.noise_sigma    = 0.02f;
    const std::vector<float> signal = make_signal(sig);

    // ── Build channel with optional grpc-direct interceptor ──────────────────
    std::shared_ptr<grpc::Channel> channel;
#ifndef STANDARD_GRPC_ONLY
    DirectTransportInterceptorFactory* factory_ptr = nullptr;
#endif

    constexpr int kMaxMsgBytes = 256 * 1024 * 1024;  // 256 MB
    grpc::ChannelArguments chan_args;
    chan_args.SetMaxReceiveMessageSize(kMaxMsgBytes);
    chan_args.SetMaxSendMessageSize(kMaxMsgBytes);

#ifdef STANDARD_GRPC_ONLY
    std::cout << "  [transport] standard gRPC (no grpc-direct interceptor)\n";
    channel = grpc::CreateCustomChannel(server,
        grpc::InsecureChannelCredentials(), chan_args);
#else
    if (is_standard_grpc(transport_str)) {
        std::cout << "  [transport] standard gRPC (no grpc-direct interceptor)\n";
        channel = grpc::CreateCustomChannel(server,
            grpc::InsecureChannelCredentials(), chan_args);
    } else {
        auto transport = parse_transport(transport_str);
        auto factory   = std::make_unique<DirectTransportInterceptorFactory>(transport);
        factory_ptr    = factory.get();
        std::vector<std::unique_ptr<grpc::experimental::ClientInterceptorFactoryInterface>> interceptors;
        interceptors.push_back(std::move(factory));
        channel = grpc::experimental::CreateCustomChannelWithInterceptors(
            server,
            grpc::InsecureChannelCredentials(),
            chan_args,
            std::move(interceptors));
    }
#endif

    auto stub = pipeline_fft::PipelineFFTService::NewStub(channel);

    // ── Wait for server to be ready ───────────────────────────────────────────
    const auto deadline = std::chrono::system_clock::now() + std::chrono::seconds(30);
    if (!channel->WaitForConnected(deadline)) {
        std::cerr << "[client] Could not connect to server at " << server
                  << " within 30s\n";
        return 1;
    }
    std::cout << "  connected!\n\n";

    // ── Stream buffers via client streaming RPC ───────────────────────────────
    grpc::ClientContext       ctx;
    pipeline_fft::PipelineSummary summary;
    auto writer = stub->StreamBuffers(&ctx, &summary);

    const auto t_stream_start = std::chrono::steady_clock::now();

    // For standard gRPC transport use the raw bytes field to bypass the
    // grpc-direct zero-copy interceptor (triggered for FloatArray >= 32 KB).
#ifndef STANDARD_GRPC_ONLY
    const bool use_raw_bytes = is_standard_grpc(transport_str);
#endif

    int sent = 0;
    for (int i = 0; i < total_send; ++i) {
        pipeline_fft::BufferRequest req;

        // Populate float32 samples
#ifdef STANDARD_GRPC_ONLY
        req.set_raw_samples(
            reinterpret_cast<const char*>(signal.data()),
            signal.size() * sizeof(float));
#else
        if (use_raw_bytes) {
            req.set_raw_samples(
                reinterpret_cast<const char*>(signal.data()),
                signal.size() * sizeof(float));
        } else {
            req.mutable_samples()->mutable_values()->Assign(
                signal.begin(), signal.end());
        }
#endif

        // Sender-side wall-clock timestamp for optional e2e latency computation
        const auto now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        req.set_send_timestamp_ns(now_ns);
        req.set_seq_num(i);

        if (!writer->Write(req)) {
            std::cerr << "[client] Write failed at buffer " << i << "\n";
            break;
        }
        ++sent;

#ifndef STANDARD_GRPC_ONLY
        // Pace sends.  Two reasons:
        //  1. The grpc-direct shared-memory ring is fire-and-forget with no
        //     backpressure: if the client outruns the server's handler thread
        //     the ring silently drops messages.
        //  2. Fair comparison: the H->D cudaMemcpy latency is transport-
        //     independent but depends on GPU clock state.  An unpaced blast
        //     keeps the GPU boosted (fast H->D) while a paced feed lets it
        //     idle and downclock (slow H->D).  To compare transports fairly we
        //     pace *every* transport identically so the GPU clock state — and
        //     therefore the H->D baseline — is the same for standard and shmem.
        // A yielding sleep is used rather than a busy spin because the client
        // and server share the host for shmem; a spin-wait would steal a CPU
        // core from the server's CUDA driver threads.
        if (pace_us > 0) {
            std::this_thread::sleep_for(std::chrono::microseconds(pace_us));
        }
#endif
    }

    writer->WritesDone();
    const grpc::Status status = writer->Finish();

    const double elapsed_s = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t_stream_start).count();

    if (!status.ok()) {
        std::cerr << "[client] RPC failed: " << status.error_message() << "\n";
#ifndef STANDARD_GRPC_ONLY
        if (factory_ptr) factory_ptr->Disconnect(channel);
#endif
        return 1;
    }

    // ── Print client-side stats ───────────────────────────────────────────────
    const double total_mb_sent = static_cast<double>(sent)
                                 * buf_size * sizeof(float) / 1e6;
    std::cout << "  Sent          : " << sent << " / " << total_send << " buffers\n"
              << "  Elapsed       : " << elapsed_s << " s\n"
              << "  Client TX rate: " << total_mb_sent / elapsed_s << " MB/s\n\n";

    // Server-computed summary is now in `summary`
    if (summary.buffers_received() == 0) {
        std::cerr << "[client] Server reported 0 buffers received.\n";
    }

#ifndef STANDARD_GRPC_ONLY
    // Drain wait: for shmem/tcp-direct transports the buffers are still being
    // consumed by the server's handler thread from the shared-memory ring after
    // Finish() returns.  Disconnecting immediately tears down the transport
    // before the server's StreamBuffersPerMessage handler drains them.  Hold the
    // connection open long enough for the server to process every buffer, then
    // for it to run its idle-timeout finalization (5 s) and flush the CSV.
    if (!is_standard_grpc(transport_str)) {
        std::cout << "  Draining shmem ring (letting server finalize)...\n";
        std::this_thread::sleep_for(std::chrono::seconds(6));
    }
    if (factory_ptr) factory_ptr->Disconnect(channel);
#endif
    return 0;
}
