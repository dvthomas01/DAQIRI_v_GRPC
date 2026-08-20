// extbuf_fft_client.cc — Phase 3 step 5 sender.  Runs on the NI PXIe-8881.
//
// No CUDA and no verbs.  This is a plain grpc-direct RDMA client: it connects,
// then calls grpc_direct_client_send in a loop.  Everything interesting happens
// on the receiver.
//
// WHY THIS DOES NOT WAIT FOR RESPONSES
// grpc_direct_client_send on the RDMA path acquires a send region, copies into
// it, queues it, and returns.  It does not block on a reply.  So calling it
// repeatedly without ever calling try_receive gives a streaming producer, and
// back-pressure still exists: AcquireSendRegion blocks once all send slots are
// in flight, and a slot only frees when the receiver has re-queued the
// corresponding receive slot.  That is exactly the flow control Phase 4 needs
// to report as blocked-send time, so it is measured here.
//
// The pending-response handle is deliberately not destroyed.  On the RDMA path
// it points into a thread-local slot that the next send overwrites, so there is
// nothing to free and calling destroy on it would be reasoning about a lifetime
// that does not exist.
//
// ONE COPY HAPPENS HERE, AND THAT IS FINE
// The payload is generated into a local buffer and memcpy'd into the send
// region.  The sender is not the measured side: the window committed to in
// section 1 of the plan starts when the receiver observes arrival.  Removing
// this copy would need the send path's zero-copy reserve/commit API and would
// change nothing we are measuring.
//
// Build on the PXI:
//   g++ -O2 -std=c++17 -o extbuf_fft_client extbuf_fft_client.cc signal_gen.cc \
//       -I. -I$HOME/grpc-direct/include \
//       -L$HOME/grpc-direct/target/release -lgrpc_direct -pthread
//
// Run (GRPC_DIRECT_RDMA_LOCAL is required cross-machine; without it the client
// binds to the remote address and cannot connect):
//   GRPC_DIRECT_RDMA_LOCAL=192.168.20.2 \
//   LD_LIBRARY_PATH=$HOME/grpc-direct/target/release \
//   ./extbuf_fft_client --host 192.168.20.1 --port 18800 --npts 4096 --msgs 200

#include "rdma_contract.h"
#include "signal_gen.h"

#include <grpc_direct.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using contract::ExtFrameHeader;
using contract::kExtFlagLast;
using contract::kExtMagic;
using contract::kPayloadOffset;
using contract::kSampleRateHz;
using contract::payload_tone_hz;

static double now_us() {
    using namespace std::chrono;
    return duration<double, std::micro>(steady_clock::now().time_since_epoch())
        .count();
}

static void usage() {
    std::printf(
        "extbuf_fft_client — Phase 3 step 5 sender\n"
        "\n"
        "  --host    IP   receiver's RoCE address (default 192.168.20.1)\n"
        "  --port    N    base port, must match the receiver (default 18800)\n"
        "  --npts    N    samples per message (default 4096)\n"
        "  --msgs    N    messages to send (default 200)\n"
        "  --pace-us N    sleep between sends; 0 = as fast as credit allows\n"
        "  --warmup  N    messages sent before timing starts (default 20)\n");
}

int main(int argc, char** argv) {
    std::string host = "192.168.20.1";
    uint32_t    port    = 18800;
    int         npts    = 4096;
    int         msgs    = 200;
    int         pace_us = 0;
    int         warmup  = 20;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { usage(); std::exit(1); }
            return argv[++i];
        };
        if      (a == "--host")    host = next();
        else if (a == "--port")    port = static_cast<uint32_t>(std::stoul(next()));
        else if (a == "--npts")    npts = std::stoi(next());
        else if (a == "--msgs")    msgs = std::stoi(next());
        else if (a == "--pace-us") pace_us = std::stoi(next());
        else if (a == "--warmup")  warmup = std::stoi(next());
        else { usage(); return 1; }
    }

    if (!std::getenv("GRPC_DIRECT_RDMA_LOCAL"))
        std::fprintf(stderr,
                     "WARNING: GRPC_DIRECT_RDMA_LOCAL is unset. The client will "
                     "bind to the remote address, which cannot work across "
                     "machines. Set it to this box's RoCE address.\n");

    const size_t frame_bytes = contract::ext_frame_bytes(static_cast<uint32_t>(npts));
    std::vector<unsigned char> frame(frame_bytes, 0);
    auto* hdr = reinterpret_cast<ExtFrameHeader*>(frame.data());
    auto* pay = reinterpret_cast<float*>(frame.data() + kPayloadOffset);

    // The tone changes every message, which is what makes the receiver's check
    // capable of failing. A fixed payload would verify clean against a stale
    // slot, and staleness is the exact hazard this whole path is arranged
    // around. Sixteen distinct signals, generated once, indexed by seq.
    std::vector<std::vector<float>> signals(16, std::vector<float>(npts));
    for (uint32_t s = 0; s < 16; ++s) {
        SignalConfig cfg;
        cfg.sample_rate_hz = kSampleRateHz;
        cfg.buffer_size    = npts;
        cfg.freqs_hz       = {payload_tone_hz(s)};
        cfg.amplitudes     = {1.0f};
        generate_signal(cfg, signals[s].data(), npts);
    }

    std::printf("connecting to %s:%u ...\n", host.c_str(), port);
    std::fflush(stdout);

    GrpcDirectClient* cli = grpc_direct_client_create(
        "extbuf_fft", GRPC_DIRECT_TRANSPORT_RDMA, host.c_str(), port);
    if (!cli) {
        std::fprintf(stderr, "FATAL: grpc_direct_client_create returned NULL\n");
        return 2;
    }
    std::printf("connected; sending %d messages of %zu bytes\n\n", msgs, frame_bytes);

    // Blocked-send time is the interesting number on this side. It is the time
    // client_send spends waiting for a send region, which is the time the
    // receiver has not given back a slot. Reported separately from anything
    // else, because folding it into a latency figure would misrepresent both
    // this arm and the shmem arm, which drops rather than blocks.
    std::vector<double> send_us;
    send_us.reserve(msgs);
    uint64_t failed = 0;
    const double t_start = now_us();

    for (int m = 0; m < msgs; ++m) {
        const uint32_t seq = static_cast<uint32_t>(m);
        hdr->magic     = kExtMagic;
        hdr->seq       = seq;
        hdr->n_samples = static_cast<uint32_t>(npts);
        hdr->flags     = (m == msgs - 1) ? kExtFlagLast : 0u;
        std::memcpy(pay, signals[seq % 16].data(), npts * sizeof(float));

        const double s0 = now_us();
        GrpcDirectPendingResponse* p =
            grpc_direct_client_send(cli, frame.data(), frame_bytes);
        const double s1 = now_us();
        (void)p;  // see the header comment: nothing to free on the RDMA path

        if (!p) {
            ++failed;
            std::fprintf(stderr, "  send failed at seq %u\n", seq);
            break;
        }
        if (m >= warmup) send_us.push_back(s1 - s0);
        if (pace_us > 0)
            std::this_thread::sleep_for(std::chrono::microseconds(pace_us));
    }

    const double t_total = now_us() - t_start;

    std::sort(send_us.begin(), send_us.end());
    auto pct = [&](double p) {
        if (send_us.empty()) return 0.0;
        return send_us[static_cast<size_t>(p * (send_us.size() - 1))];
    };
    double sum = 0.0;
    for (double v : send_us) sum += v;

    std::printf("sent              : %llu of %d (%llu failed)\n",
                (unsigned long long)(msgs - failed), msgs,
                (unsigned long long)failed);
    std::printf("send call p50/p99 : %.2f / %.2f us  (%zu timed, %d warmup skipped)\n",
                pct(0.50), pct(0.99), send_us.size(), warmup);
    std::printf("blocked in send   : %.1f us total, %.1f%% of wall time\n",
                sum, t_total > 0 ? 100.0 * sum / t_total : 0.0);
    std::printf("wall              : %.1f us\n", t_total);

    grpc_direct_client_destroy(cli);
    std::printf("DONE_EXTBUF_CLIENT rc=%d\n", failed ? 1 : 0);
    return failed ? 1 : 0;
}
