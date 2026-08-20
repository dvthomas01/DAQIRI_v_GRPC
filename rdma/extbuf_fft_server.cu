// extbuf_fft_server.cu — Phase 3 step 5 receiver.  Runs on the Spark.
//
// WHAT THIS IS
// The first program in which the whole architecture runs through the real
// transport rather than around it.  The PXI sends over RoCE, grpc-direct's RDMA
// path receives, and the bytes land in a cudaHostAlloc'd pool this program
// allocated, which cuFFT then transforms in place.  No copy anywhere on the
// receive path.
//
// Phase 2 proved the same thing with raw ibverbs and a hand-rolled credit
// protocol.  That was the point of Phase 2: get the data path right somewhere
// small before putting it inside a library.  This is the library version.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE ONE RULE
//
// grpc_direct_server_slot_requeue() is the entire lifetime contract.  There is
// no release call on the external-buffer path: a slot goes back to idle when
// its completion callback fires, and re-queueing is both the re-arm and the
// flow-control credit.  So the slot's contents belong to us from the moment
// receive_ext returns until the moment we re-queue, and belong to the NIC
// immediately afterwards.
//
// The re-queue therefore has to sit behind a CUDA event recorded after the
// transform, not behind the transform's launch.  It does, at the one place
// marked THE GATE below.
//
// Right now that event synchronise is redundant, because CuFFTExecutor::execute
// blocks until the transform is complete, so the work is already done by the
// time we reach it.  It is written explicitly anyway.  Step 6 replaces execute
// with an asynchronous launch to demonstrate the race, and when it does, the
// gate is already in the right place and the diff shows only the launch
// changing.  A correctness property that depends on a callee's blocking
// behaviour, undocumented at the call site, is a property that survives exactly
// until someone optimises the callee.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT IS AND IS NOT QUOTABLE FROM THIS PROGRAM
//
// e2e_us is measured from receive_ext returning to the post-transform event
// completing.  That is the post-arrival window section 1 of the plan commits
// to, and it is comparable with the existing arms.
//
// Throughput and inter-message gap are NOT quotable with --poison on or
// --verify every, because both run after the timer stops but before the
// re-queue, and the re-queue is the sender's credit.  Poisoning and verifying
// therefore throttle the sender.  That is the correct trade for a correctness
// harness and the wrong one for Phase 4, which runs --poison off --verify off.
//
// ─────────────────────────────────────────────────────────────────────────────
// HOT PATH DISCIPLINE
//
// Allocated, registered and pointer-translated exactly once at startup, then
// the counters freeze and any later call aborts at the call site.  Same guard
// as Phase 2, for the same reason: a per-message registration is the easiest
// way to build something slower than what we already have, and it will not
// announce itself.
//
// Build: scripts/build_extbuf_server.sh on the Spark.

#include "cufft_executor.h"
#include "grpc_direct_extbuf.h"
#include "rdma_contract.h"
#include "signal_gen.h"

#include <cuda_runtime.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using contract::ExtFrameHeader;
using contract::kExtFlagLast;
using contract::kExtMagic;
using contract::kPayloadOffset;
using contract::kPoisonToneHz;
using contract::kSampleRateHz;
using contract::payload_tone_hz;

// ─────────────────────────────────────────────────────────────────────────────
// Hot path guard
// ─────────────────────────────────────────────────────────────────────────────
namespace guard {
static bool     frozen = false;
static uint64_t allocs = 0, xlates = 0;

static void account(uint64_t& counter, const char* what) {
    if (frozen) {
        std::fprintf(stderr,
                     "\nFATAL: %s was called after startup.\n"
                     "The pool is allocated and translated exactly once. Doing "
                     "either per message is the easiest way to build something "
                     "slower than what we already have.\n",
                     what);
        std::abort();
    }
    ++counter;
}
static void freeze() { frozen = true; }
}  // namespace guard

#define CUDA_OK(call)                                                          \
    do {                                                                       \
        cudaError_t e_ = (call);                                               \
        if (e_ != cudaSuccess) {                                               \
            std::fprintf(stderr, "\nFATAL: %s -> %s\n", #call,                 \
                         cudaGetErrorString(e_));                              \
            std::exit(2);                                                      \
        }                                                                      \
    } while (0)

static void* pool_host_alloc(size_t bytes) {
    guard::account(guard::allocs, "cudaHostAlloc");
    void* p = nullptr;
    CUDA_OK(cudaHostAlloc(&p, bytes, cudaHostAllocMapped));
    return p;
}

static void* pool_device_ptr(void* host) {
    guard::account(guard::xlates, "cudaHostGetDevicePointer");
    void* d = nullptr;
    CUDA_OK(cudaHostGetDevicePointer(&d, host, 0));
    return d;
}

static double now_us() {
    using namespace std::chrono;
    return duration<double, std::micro>(steady_clock::now().time_since_epoch())
        .count();
}

static void usage() {
    std::printf(
        "extbuf_fft_server — Phase 3 step 5 receiver\n"
        "\n"
        "  --addr    IP    local RoCE address to bind (default 192.168.20.1)\n"
        "  --port    N     base port; N+1 is used for the response session\n"
        "                  (default 18800)\n"
        "  --npts    N     FFT size in samples (default 4096)\n"
        "  --msgs    N     messages to receive (default 200)\n"
        "  --slots   N     pool slots (default 4; step 6 uses 2)\n"
        "  --poison  on|off   repaint each slot before re-queueing (default on)\n"
        "  --verify  every|off  spectral check per message (default every)\n"
        "  --own-stream    run cuFFT on its own stream\n"
        "  --tol-bins N    peak tolerance in bins (default 2)\n"
        "  --csv     PATH  per-message CSV\n"
        "  --sha     STR   git SHA stamped into every CSV row\n");
}

int main(int argc, char** argv) {
    std::string addr = "192.168.20.1";
    std::string csv_path, git_sha = "unknown";
    uint32_t    port     = 18800;
    int         npts     = 4096;
    int         msgs     = 200;
    int         slots    = 4;
    int         tol_bins = 2;
    bool        poison_on = true, verify_on = true, own_stream = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { usage(); std::exit(1); }
            return argv[++i];
        };
        if      (a == "--addr")       addr = next();
        else if (a == "--port")       port = static_cast<uint32_t>(std::stoul(next()));
        else if (a == "--npts")       npts = std::stoi(next());
        else if (a == "--msgs")       msgs = std::stoi(next());
        else if (a == "--slots")      slots = std::stoi(next());
        else if (a == "--tol-bins")   tol_bins = std::stoi(next());
        else if (a == "--poison")     poison_on = (next() == "on");
        else if (a == "--verify")     verify_on = (next() != "off");
        else if (a == "--own-stream") own_stream = true;
        else if (a == "--csv")        csv_path = next();
        else if (a == "--sha")        git_sha = next();
        else { usage(); return 1; }
    }
    if (slots < 2) {
        std::fprintf(stderr, "--slots must be at least 2\n");
        return 1;
    }

    // ── the pool ─────────────────────────────────────────────────────────
    // Slot size is rounded up to a multiple of kPayloadOffset so that, given a
    // page-aligned pool, every payload lands on a 256-byte boundary.  cuFFT
    // rejects under-aligned input outright, so this is a correctness
    // requirement rather than a tuning choice.
    const size_t frame_bytes = contract::ext_frame_bytes(static_cast<uint32_t>(npts));
    const size_t slot_bytes  = ((frame_bytes + kPayloadOffset - 1) / kPayloadOffset)
                               * kPayloadOffset;
    const size_t pool_bytes  = slot_bytes * static_cast<size_t>(slots);

    auto* h_pool = static_cast<unsigned char*>(pool_host_alloc(pool_bytes));
    auto* d_pool = static_cast<unsigned char*>(pool_device_ptr(h_pool));

    std::printf("pool              : %zu bytes, %d slots of %zu\n",
                pool_bytes, slots, slot_bytes);
    std::printf("host / device ptr : %p / %p%s\n", (void*)h_pool, (void*)d_pool,
                (h_pool == d_pool) ? "  (identical, GB10 is coherent)" : "");
    std::printf("payload offset    : %zu bytes into each slot\n", kPayloadOffset);

    // ── poison, generated once ───────────────────────────────────────────
    SignalConfig poison_cfg;
    poison_cfg.sample_rate_hz = kSampleRateHz;
    poison_cfg.buffer_size    = npts;
    poison_cfg.freqs_hz       = {kPoisonToneHz};
    poison_cfg.amplitudes     = {1.0f};
    std::vector<float> poison(npts);
    generate_signal(poison_cfg, poison.data(), npts);

    // Paint every slot before the NIC is armed.  From here on a slot may only
    // be repainted while we own it, which is between receive_ext and requeue.
    for (int s = 0; s < slots; ++s)
        std::memcpy(h_pool + static_cast<size_t>(s) * slot_bytes + kPayloadOffset,
                    poison.data(), npts * sizeof(float));

    CuFFTExecutor fft(npts, own_stream);
    cufftComplex* d_out = nullptr;
    CUDA_OK(cudaMalloc(&d_out, sizeof(cufftComplex) * (npts / 2 + 1)));

    cudaEvent_t consumed;
    CUDA_OK(cudaEventCreateWithFlags(&consumed, cudaEventDisableTiming));

    guard::freeze();
    const uint64_t frozen_allocs = guard::allocs, frozen_xlates = guard::xlates;

    // ── connect ──────────────────────────────────────────────────────────
    std::printf("\nwaiting for the sender on %s:%u ...\n", addr.c_str(), port);
    std::fflush(stdout);

    GrpcDirectServer* srv = grpc_direct_server_create_ext(
        "extbuf_fft", GRPC_DIRECT_TRANSPORT_RDMA, addr.c_str(), port,
        h_pool, pool_bytes, slot_bytes);
    if (!srv) {
        std::fprintf(stderr, "FATAL: grpc_direct_server_create_ext returned NULL\n");
        return 2;
    }
    std::printf("connected\n\n");

    std::FILE* csv = nullptr;
    if (!csv_path.empty()) {
        csv = std::fopen(csv_path.c_str(), "w");
        if (!csv) { std::perror("fopen"); return 2; }
        std::fprintf(csv, "seq,slot,bytes,npts,e2e_us,fft_us,peak_hz,expect_hz,ok,gitsha\n");
    }

    // ── the loop ─────────────────────────────────────────────────────────
    const float bin_hz = kSampleRateHz / static_cast<float>(npts);
    const float tol_hz = bin_hz * static_cast<float>(tol_bins);

    uint64_t received = 0, verified = 0, bad_spectrum = 0, bad_frame = 0;
    float    worst_err_hz = 0.0f, worst_seen_hz = 0.0f, worst_expect_hz = 0.0f;
    std::vector<double> e2e;
    e2e.reserve(msgs);

    for (int m = 0; m < msgs; ++m) {
        const uint8_t* ptr  = nullptr;
        size_t         len  = 0;
        size_t         slot = 0;

        GrpcDirectActiveRequest* ar =
            grpc_direct_server_receive_ext(srv, &ptr, &len, &slot);
        if (!ar) {
            std::fprintf(stderr, "receive_ext returned NULL after %llu messages "
                                 "(sender gone, or a completion reported an error)\n",
                         (unsigned long long)received);
            break;
        }
        const double t0 = now_us();
        ++received;

        // The landing buffer is demonstrably ours.  Asserted, not intended:
        // if grpc-direct ever falls back to driver-allocated buffers, every
        // transfer keeps working and only this check notices.
        const unsigned char* expect_base = h_pool + slot * slot_bytes;
        if (ptr != expect_base || slot >= static_cast<size_t>(slots) ||
            !(ptr >= h_pool && ptr + len <= h_pool + pool_bytes)) {
            std::fprintf(stderr,
                         "\nFATAL: payload landed outside our pool, or in the "
                         "wrong slot.\n  ptr %p, slot %zu, expected %p, pool "
                         "[%p, %p)\n"
                         "This is the failure the external-buffer path exists to "
                         "make impossible. Do not measure anything until it is "
                         "explained.\n",
                         (const void*)ptr, slot, (const void*)expect_base,
                         (const void*)h_pool, (const void*)(h_pool + pool_bytes));
            std::abort();
        }

        const auto* hdr = reinterpret_cast<const ExtFrameHeader*>(ptr);
        const bool  frame_ok =
            hdr->magic == kExtMagic && hdr->n_samples == static_cast<uint32_t>(npts) &&
            len >= contract::ext_frame_bytes(hdr->n_samples);
        if (!frame_ok) {
            ++bad_frame;
            std::fprintf(stderr,
                         "  bad frame in slot %zu: magic %08x (want %08x), "
                         "n_samples %u (want %d), len %zu\n",
                         slot, hdr->magic, kExtMagic, hdr->n_samples, npts, len);
        }

        const uint32_t seq  = hdr->seq;
        const bool     last = (hdr->flags & kExtFlagLast) != 0;

        // ── THE ORDERING RULE ────────────────────────────────────────────
        // The completion has been observed (receive_ext returned). Only now is
        // the transform launched, on this same thread. These two statements
        // must stay adjacent and in this order.
        const float* d_payload =
            reinterpret_cast<const float*>(d_pool + slot * slot_bytes + kPayloadOffset);
        if (frame_ok) fft.execute(d_payload, d_out);

        // ── THE GATE ─────────────────────────────────────────────────────
        // Nothing below may touch the slot until this event has completed, and
        // the re-queue below hands the slot to the NIC.  Currently redundant
        // because execute() blocks; see the header comment for why it is here.
        CUDA_OK(cudaEventRecord(consumed, fft.stream()));
        CUDA_OK(cudaEventSynchronize(consumed));

        const double t1 = now_us();
        e2e.push_back(t1 - t0);

        // Everything from here to the re-queue runs outside the timed window
        // and delays the sender's credit.  Correct for a harness, wrong for
        // Phase 4; run with --poison off --verify off there.
        float peak_hz = -1.0f, expect_hz = payload_tone_hz(seq);
        bool  ok = frame_ok;
        if (frame_ok && verify_on) {
            auto peaks = fft.detect_peaks(d_out, 3, kSampleRateHz);
            peak_hz    = peaks.empty() ? -1.0f : peaks[0].first;
            const float err = std::fabs(peak_hz - expect_hz);
            ok = err <= tol_hz;
            if (ok) {
                ++verified;
            } else {
                ++bad_spectrum;
                if (err > worst_err_hz) {
                    worst_err_hz    = err;
                    worst_seen_hz   = peak_hz;
                    worst_expect_hz = expect_hz;
                }
            }
        }

        if (poison_on)
            std::memcpy(h_pool + slot * slot_bytes + kPayloadOffset,
                        poison.data(), npts * sizeof(float));

        if (csv)
            std::fprintf(csv, "%u,%zu,%zu,%d,%.3f,%.3f,%.1f,%.1f,%d,%s\n",
                         seq, slot, len, npts, t1 - t0, fft.last_exec_us(),
                         peak_hz, expect_hz, ok ? 1 : 0, git_sha.c_str());

        grpc_direct_request_destroy(ar);

        // Hand the slot back. After this instruction the NIC may overwrite it.
        const int32_t rq = grpc_direct_server_slot_requeue(srv, slot);
        if (rq != 0) {
            std::fprintf(stderr, "\nFATAL: slot_requeue(%zu) -> %d\n", slot, rq);
            std::abort();
        }

        if (guard::allocs != frozen_allocs || guard::xlates != frozen_xlates) {
            std::fprintf(stderr, "\nFATAL: the pool changed during the run\n");
            std::abort();
        }
        if (last) break;
    }

    if (csv) std::fclose(csv);

    // ── report ───────────────────────────────────────────────────────────
    std::sort(e2e.begin(), e2e.end());
    auto pct = [&](double p) {
        if (e2e.empty()) return 0.0;
        size_t i = static_cast<size_t>(p * (e2e.size() - 1));
        return e2e[i];
    };

    std::printf("\n");
    std::printf("received          : %llu of %d\n", (unsigned long long)received, msgs);
    std::printf("verified          : %llu\n", (unsigned long long)verified);
    std::printf("bad spectrum      : %llu\n", (unsigned long long)bad_spectrum);
    std::printf("bad frame         : %llu\n", (unsigned long long)bad_frame);
    if (bad_spectrum)
        std::printf("worst peak        : %.0f Hz, expected %.0f\n",
                    worst_seen_hz, worst_expect_hz);
    std::printf("e2e p50 / p99     : %.2f / %.2f us  (post-arrival, %zu samples)\n",
                pct(0.50), pct(0.99), e2e.size());
    std::printf("pool operations   : %llu alloc, %llu translate "
                "(unchanged since startup: %s)\n",
                (unsigned long long)guard::allocs, (unsigned long long)guard::xlates,
                (guard::allocs == frozen_allocs && guard::xlates == frozen_xlates)
                    ? "YES" : "NO");

    const bool pass = received > 0 && bad_frame == 0 &&
                      (!verify_on || (bad_spectrum == 0 && verified == received));
    std::printf("\n%s\n", pass ? "ALL RECEIVED MESSAGES VERIFIED" : "FAILURES PRESENT");

    grpc_direct_server_shutdown(srv);
    grpc_direct_server_destroy(srv);
    cudaFree(d_out);
    cudaEventDestroy(consumed);
    cudaFreeHost(h_pool);

    std::printf("DONE_EXTBUF rc=%d\n", pass ? 0 : 1);
    return pass ? 0 : 1;
}
