// extbuf_fft_client.cc — Phase 3 step 5 sender.  Runs on the NI PXIe-8881.
//
// No CUDA and no verbs.  This is a plain grpc-direct RDMA client: it connects,
// then calls grpc_direct_client_send in a loop.  Everything interesting happens
// on the receiver.
//
// WHY THIS DOES NOT WAIT FOR RESPONSES, IN STREAMING MODE
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
// --ECHO ON, AND WHAT IT COSTS
// With --echo on the receiver replies sixteen bytes after its transform
// completes, and this program times the whole span on its own clock.  That is
// the only way to get a post-to-transform-complete number here, because the two
// boxes' realtime clocks are 23.13 seconds apart and neither runs NTP, so
// subtracting one from the other produces a number off by seven orders of
// magnitude in the wrong direction.
//
// The cost is that the same thread-local pending slot means one reply may be
// outstanding at a time, so waiting for it serialises the sender completely.
// Echo mode measures UNLOADED latency: one buffer, no pipelining, no queueing.
// It is not the steady-state latency of a loaded pipeline and it must not be
// reported next to a throughput number from a streaming run as though the two
// described the same experiment.  Sustained rate comes from the receiver's
// inter-arrival gap, in a separate run with --echo off.
//
// The return path is inside the measured span, so it is calibrated out: run the
// receiver with --fft off and a tiny --npts, which measures request-and-return
// with no work in the middle, and subtract that p50 from the full run's.
//
// ONE COPY HAPPENS HERE, AND IT IS NOT FREE
// The payload is generated into a local buffer and memcpy'd into the send
// region.  At 4 MB that is two host copies of four mebibytes each before a byte
// reaches the wire: this one, and the library's own copy inside client_send.
// The first is timed separately as gen_us and the second is inside send_us, so
// that a send_us of two milliseconds against a 685 us wire time can be
// attributed rather than guessed at.  It was previously described here as fine
// because the sender is not the measured side.  That was true of the window we
// were measuring and false of the pipeline, which is the point of --echo.
//
// As of --gen inplace it is also removable.  Once the receiver stopped holding
// the sender's credit, gen_us at 468 us plus send_us at 335 us accounted for
// essentially all of an 800 us inter-arrival, which makes this the bottleneck
// rather than a footnote.  --gen inplace builds the sixteen frames complete at
// startup so the loop writes only a header, leaving the library's copy as the
// only one.  Run it paired against --gen copy.  The result decides whether the
// receive path's 85 percent of link is a transport limit or a harness limit,
// and those are different claims.
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

using contract::EchoAck;
using contract::ExtFrameHeader;
using contract::kEchoMagic;
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
        "  --warmup  N    messages sent before timing starts (default 20)\n"
        "  --linger-ms N  wait before teardown so in-flight sends drain\n"
        "                 (default 200)\n"
        "  --echo    on|off  wait for the receiver's ack after every message\n"
        "                 and time post-to-transform-complete on this box's\n"
        "                 clock (default off). The receiver must be run with\n"
        "                 --echo on too. Serialises the sender, so the result\n"
        "                 is unloaded latency, not pipeline latency.\n"
        "  --gen  copy|inplace  how the payload reaches the frame (default\n"
        "                 copy). copy generates once at startup and memcpy's\n"
        "                 4 MiB into the frame every message, which is what\n"
        "                 gen_us measures. inplace builds sixteen complete\n"
        "                 frames at startup and writes only the header per\n"
        "                 message. Pair the two: the difference is how much of\n"
        "                 the sender's limit is the harness generating data a\n"
        "                 real digitiser would have DMA'd in already.\n"
        "  --csv     PATH per-message CSV: seq,gen_us,send_us,rtt_us\n");
}

int main(int argc, char** argv) {
    std::string host = "192.168.20.1";
    std::string csv_path;
    uint32_t    port    = 18800;
    int         npts    = 4096;
    int         msgs    = 200;
    int         pace_us = 0;
    int         warmup  = 20;
    int         linger_ms = 200;
    bool        echo_on = false;
    std::string gen_mode = "copy";

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
        else if (a == "--linger-ms") linger_ms = std::stoi(next());
        else if (a == "--gen")     gen_mode = next();
        else if (a == "--echo")    echo_on = (next() == "on");
        else if (a == "--csv")     csv_path = next();
        else { usage(); return 1; }
    }

    if (gen_mode != "copy" && gen_mode != "inplace") {
        std::fprintf(stderr, "--gen must be copy or inplace, got '%s'\n",
                     gen_mode.c_str());
        return 1;
    }

    if (!std::getenv("GRPC_DIRECT_RDMA_LOCAL"))
        std::fprintf(stderr,
                     "WARNING: GRPC_DIRECT_RDMA_LOCAL is unset. The client will "
                     "bind to the remote address, which cannot work across "
                     "machines. Set it to this box's RoCE address.\n");

    const size_t frame_bytes = contract::ext_frame_bytes(static_cast<uint32_t>(npts));

    // ── THE SENDER'S OWN COPY, AND THE ARM THAT REMOVES IT ───────────────────
    // In copy mode the payload is generated into signals[] once and memcpy'd
    // into the frame every message. That memcpy is gen_us. It is 4 MiB of
    // single-threaded host bandwidth on the PXI and at 4 MiB it is roughly 468
    // us, against a 685 us wire time, so it is not a rounding error: it is
    // comparable to the transfer it is preparing for.
    //
    // In inplace mode the sixteen frames are built complete at startup, payload
    // and all, and the send loop writes only the 16-byte header of whichever one
    // is due. gen_us collapses to the header write. Nothing else changes, which
    // is the point: this is a paired arm against copy, not a replacement for it.
    //
    // Why this is worth measuring rather than assuming. A real digitiser DMAs
    // into a buffer you then hand to the transport; it does not stage the
    // waveform somewhere else first and copy it in. The copy mode arm is an
    // artefact of the harness generating its own data. If removing it moves the
    // rate, then the 85 percent of link the receive path sustains is limited by
    // the harness and not by the transport, and that is a different claim from
    // the one currently written down.
    //
    // Reusing a frame every sixteen messages is safe because client_send copies
    // into the send region before it returns. That copy is the other 4 MiB and
    // it belongs to the library, so this arm cannot remove it.
    const bool inplace = (gen_mode == "inplace");

    std::vector<std::vector<unsigned char>> frames;
    std::vector<unsigned char>              frame;
    std::vector<std::vector<float>>         signals;

    auto fill_payload = [&](uint32_t s, float* dst) {
        SignalConfig cfg;
        cfg.sample_rate_hz = kSampleRateHz;
        cfg.buffer_size    = npts;
        cfg.freqs_hz       = {payload_tone_hz(s)};
        cfg.amplitudes     = {1.0f};
        generate_signal(cfg, dst, npts);
    };

    // The tone changes every message, which is what makes the receiver's check
    // capable of failing. A fixed payload would verify clean against a stale
    // slot, and staleness is the exact hazard this whole path is arranged
    // around. Sixteen distinct signals either way, so the two arms present the
    // receiver with identical traffic and only the sender's work differs.
    if (inplace) {
        frames.resize(16);
        for (uint32_t s = 0; s < 16; ++s) {
            frames[s].assign(frame_bytes, 0);
            fill_payload(s, reinterpret_cast<float*>(frames[s].data() + kPayloadOffset));
        }
    } else {
        frame.assign(frame_bytes, 0);
        signals.assign(16, std::vector<float>(npts));
        for (uint32_t s = 0; s < 16; ++s) fill_payload(s, signals[s].data());
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
    //
    // gen_us is separated from it so that the sender's own copy is visible.
    // send_us contains the library's copy into the send region; gen_us contains
    // ours into the frame. At 4 MB neither is small, and until they were split
    // out a send_us of 2100 us was being read as fabric time.
    std::vector<double> send_us, gen_us, rtt_us;
    send_us.reserve(msgs);
    gen_us.reserve(msgs);
    rtt_us.reserve(msgs);
    uint64_t failed = 0, bad_ack = 0;

    std::FILE* csv = nullptr;
    if (!csv_path.empty()) {
        csv = std::fopen(csv_path.c_str(), "w");
        if (!csv) { std::perror("fopen"); return 2; }
        std::fprintf(csv, "seq,gen_us,send_us,rtt_us\n");
    }

    const double t_start = now_us();

    for (int m = 0; m < msgs; ++m) {
        const uint32_t seq = static_cast<uint32_t>(m);

        const double g0 = now_us();
        unsigned char* buf = inplace ? frames[seq % 16].data() : frame.data();
        auto* hdr = reinterpret_cast<ExtFrameHeader*>(buf);
        hdr->magic     = kExtMagic;
        hdr->seq       = seq;
        hdr->n_samples = static_cast<uint32_t>(npts);
        hdr->flags     = (m == msgs - 1) ? kExtFlagLast : 0u;
        if (!inplace)
            std::memcpy(reinterpret_cast<float*>(buf + kPayloadOffset),
                        signals[seq % 16].data(), npts * sizeof(float));
        const double g1 = now_us();

        const double s0 = now_us();
        GrpcDirectPendingResponse* p =
            grpc_direct_client_send(cli, buf, frame_bytes);
        const double s1 = now_us();

        if (!p) {
            ++failed;
            std::fprintf(stderr, "  send failed at seq %u\n", seq);
            break;
        }

        // In streaming mode there is nothing to free: see the header comment.
        // In echo mode the wait consumes the handle, and the span from s0 to
        // here is the whole point of the run.
        double rtt = 0.0;
        if (echo_on) {
            const uint8_t* resp = nullptr;
            size_t         rlen = 0;
            if (grpc_direct_client_wait_receive(p, &resp, &rlen) != 0) {
                ++failed;
                std::fprintf(stderr, "  no ack for seq %u\n", seq);
                break;
            }
            const double s2 = now_us();
            rtt = s2 - s0;

            // An ack for the wrong message would silently produce a latency for
            // a transform that has not happened yet, which is the same class of
            // error the spectral check exists to catch on the other side. It
            // replaces that check in echo mode, so it is not optional.
            if (rlen < sizeof(EchoAck)) {
                ++bad_ack;
                std::fprintf(stderr, "  ack too short at seq %u: %zu bytes\n",
                             seq, rlen);
            } else {
                EchoAck ack;
                std::memcpy(&ack, resp, sizeof(ack));
                if (ack.magic != kEchoMagic || ack.seq != seq) {
                    ++bad_ack;
                    std::fprintf(stderr,
                                 "  ack mismatch at seq %u: magic %08x seq %u\n",
                                 seq, ack.magic, ack.seq);
                }
            }
        } else {
            (void)p;  // see the header comment: nothing to free on the RDMA path
        }

        if (m >= warmup) {
            gen_us.push_back(g1 - g0);
            send_us.push_back(s1 - s0);
            if (echo_on) rtt_us.push_back(rtt);
            if (csv)
                std::fprintf(csv, "%u,%.3f,%.3f,%.3f\n", seq, g1 - g0, s1 - s0, rtt);
        }
        if (pace_us > 0)
            std::this_thread::sleep_for(std::chrono::microseconds(pace_us));
    }

    const double t_total = now_us() - t_start;
    if (csv) std::fclose(csv);

    auto pct_of = [](std::vector<double>& v, double p) {
        if (v.empty()) return 0.0;
        return v[static_cast<size_t>(p * (v.size() - 1))];
    };
    double sum = 0.0;
    for (double v : send_us) sum += v;
    std::sort(send_us.begin(), send_us.end());
    std::sort(gen_us.begin(), gen_us.end());
    std::sort(rtt_us.begin(), rtt_us.end());

    std::printf("sent              : %llu of %d (%llu failed)\n",
                (unsigned long long)(msgs - failed), msgs,
                (unsigned long long)failed);
    std::printf("frame build p50   : %.2f us  (--gen %s: %s, not on the wire)\n",
                pct_of(gen_us, 0.50), gen_mode.c_str(),
                inplace ? "16-byte header only"
                        : "our memcpy of the whole frame");
    std::printf("send call p50/p99 : %.2f / %.2f us  (%zu timed, %d warmup skipped)\n",
                pct_of(send_us, 0.50), pct_of(send_us, 0.99), send_us.size(),
                warmup);
    std::printf("blocked in send   : %.1f us total, %.1f%% of wall time\n",
                sum, t_total > 0 ? 100.0 * sum / t_total : 0.0);
    if (echo_on) {
        std::printf("echo rtt p50/p99  : %.2f / %.2f us  "
                    "(post to transform-complete, this box's clock, UNLOADED)\n",
                    pct_of(rtt_us, 0.50), pct_of(rtt_us, 0.99));
        std::printf("bad acks          : %llu\n", (unsigned long long)bad_ack);
        std::printf("  subtract a --fft off calibration run's rtt p50 to remove "
                    "the return path.\n");
    }
    std::printf("wall              : %.1f us\n", t_total);

    // Wait before tearing the session down.  client_send returns once the
    // buffer is queued, not once the peer has consumed it, so destroying the
    // client immediately aborts the session underneath whatever is still in
    // flight.  The first run lost the last three messages to exactly that: the
    // receiver reported a completion status of -734017 and stopped at 197.
    //
    // A wait is the honest fix here rather than a lazy one, because this
    // protocol has no acknowledgement to wait on.  The server never replies,
    // by design: a reply per message would add a round trip to the very path
    // being measured.  Draining by sender-side completion would not settle it
    // either, since a send completing means the bytes reached the peer's
    // memory and not that the peer's FFT has run.
    //
    // This is outside every timed region and after the last measurement, so it
    // cannot flatter any number.
    if (linger_ms > 0)
        std::this_thread::sleep_for(std::chrono::milliseconds(linger_ms));

    grpc_direct_client_destroy(cli);
    const int rc = (failed || bad_ack) ? 1 : 0;
    std::printf("DONE_EXTBUF_CLIENT rc=%d\n", rc);
    return rc;
}
