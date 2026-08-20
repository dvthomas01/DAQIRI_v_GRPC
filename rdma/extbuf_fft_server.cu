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

#include <unistd.h>

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
static uint64_t allocs = 0, xlates = 0, regs = 0;

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

// ─────────────────────────────────────────────────────────────────────────────
// The stock arm's registration table
//
// The stock path does not let us choose the landing buffer: easyrdma allocates
// four 16 MiB slots itself, out of ordinary memory that no CUDA call has ever
// seen. A kernel cannot read that, so to transform it in place we have to
// cudaHostRegister it, and that is the entire point of this arm rather than an
// inconvenience. Section 7c of the handoff measured driver-allocated pinned
// memory beating user-allocated-then-registered memory by 10.94 us of GPU time
// at 4 MB, 15 of 15 paired. This arm asks whether that survives contact with a
// real transport, with the allocator as the only difference between the two
// RDMA arms.
//
// The alternative, copying each message into a pinned staging buffer, would
// measure a copy rather than an allocator and would be a different experiment.
//
// Registration happens during a warmup that is not measured, and then the guard
// freezes. A cudaHostRegister on the hot path would swamp everything here.
// ─────────────────────────────────────────────────────────────────────────────
struct RegRegion {
    unsigned char* host = nullptr;
    unsigned char* dev  = nullptr;
    size_t         bytes = 0;
};

static std::vector<RegRegion> g_regs;
static size_t                 g_page = 4096;

// Returns the device address for [p, p+len), registering the pages that hold it
// on first sight. Registration is refused once the guard has frozen.
static const unsigned char* stock_device_ptr(const unsigned char* p, size_t len) {
    for (const auto& r : g_regs)
        if (p >= r.host && p + len <= r.host + r.bytes)
            return r.dev + (p - r.host);

    guard::account(guard::regs, "cudaHostRegister");

    auto  addr  = reinterpret_cast<uintptr_t>(p);
    auto  base  = reinterpret_cast<unsigned char*>(addr & ~(uintptr_t)(g_page - 1));
    size_t span = ((addr + len) - reinterpret_cast<uintptr_t>(base) + g_page - 1)
                  & ~(uintptr_t)(g_page - 1);

    cudaError_t e = cudaHostRegister(base, span, cudaHostRegisterMapped);
    if (e != cudaSuccess) {
        std::fprintf(stderr,
                     "\nFATAL: cudaHostRegister(%p, %zu) -> %s\n"
                     "The stock arm cannot transform a buffer it has not "
                     "registered, so there is no measurement to salvage here.\n",
                     (void*)base, span, cudaGetErrorString(e));
        std::abort();
    }
    void* d = nullptr;
    CUDA_OK(cudaHostGetDevicePointer(&d, base, 0));

    RegRegion r{base, static_cast<unsigned char*>(d), span};
    g_regs.push_back(r);
    std::printf("  registered stock slot %zu: %p .. %p (%zu bytes)\n",
                g_regs.size(), (void*)base, (void*)(base + span), span);
    return r.dev + (p - r.host);
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
        "  --warmup  N     unmeasured messages before the measured section\n"
        "                  (default 0). Needed at every size: the GB10 sits at\n"
        "                  idle clocks and takes about three seconds of load to\n"
        "                  ramp, and a short run finishes before it does.\n"
        "  --slots   N     pool slots (default 4; step 6 uses 2)\n"
        "  --poison  on|off   repaint each slot before re-queueing (default on)\n"
        "  --verify  every|off  spectral check per message (default every)\n"
        "  --own-stream    run cuFFT on its own stream\n"
        "  --tol-bins N    peak tolerance in bins (default 2)\n"
        "  --stock         rdma-stock-nopoll arm: driver-allocated buffers,\n"
        "                  registered once during warmup instead of a pool we\n"
        "                  own. No re-queue; the library owns slot lifetime.\n"
        "  --reg-warmup N  unmeasured messages before timing, used to see and\n"
        "                  register every stock slot (default 32)\n"
        "  --csv     PATH  per-message CSV\n"
        "  --sha     STR   git SHA stamped into every CSV row\n");
}

int main(int argc, char** argv) {
    std::string addr = "192.168.20.1";
    std::string csv_path, git_sha = "unknown";
    uint32_t    port     = 18800;
    int         npts     = 4096;
    int         msgs     = 200;
    int         warmup   = 0;
    int         slots    = 4;
    int         tol_bins = 2;
    int         reg_warmup = 32;
    bool        poison_on = true, verify_on = true, own_stream = false;
    bool        stock = false;

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
        else if (a == "--warmup")     warmup = std::stoi(next());
        else if (a == "--slots")      slots = std::stoi(next());
        else if (a == "--tol-bins")   tol_bins = std::stoi(next());
        else if (a == "--poison")     poison_on = (next() == "on");
        else if (a == "--verify")     verify_on = (next() != "off");
        else if (a == "--own-stream") own_stream = true;
        else if (a == "--stock")      stock = true;
        else if (a == "--reg-warmup") reg_warmup = std::stoi(next());
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

    g_page = static_cast<size_t>(sysconf(_SC_PAGESIZE));

    unsigned char* h_pool = nullptr;
    unsigned char* d_pool = nullptr;
    if (!stock) {
        h_pool = static_cast<unsigned char*>(pool_host_alloc(pool_bytes));
        d_pool = static_cast<unsigned char*>(pool_device_ptr(h_pool));
        std::printf("arm               : rdma (our pool)\n");
        std::printf("pool              : %zu bytes, %d slots of %zu\n",
                    pool_bytes, slots, slot_bytes);
        std::printf("host / device ptr : %p / %p%s\n", (void*)h_pool, (void*)d_pool,
                    (h_pool == d_pool) ? "  (identical, GB10 is coherent)" : "");
    } else {
        // The library fixes this at RDMA_MAX_FRAME_SIZE x RDMA_MAX_CONCURRENT,
        // 4 slots of 16 MiB, and offers no way to ask for fewer. So --slots is
        // meaningless here and saying so beats silently ignoring it.
        std::printf("arm               : rdma-stock-nopoll "
                    "(easyrdma's buffers, registered by us)\n");
        std::printf("pool              : chosen by the library, 4 slots of 16 MiB; "
                    "--slots ignored\n");
        std::printf("registration      : during %d unmeasured warmup messages\n",
                    reg_warmup);
    }
    std::printf("page size         : %zu bytes\n", g_page);
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
    if (!stock)
        for (int s = 0; s < slots; ++s)
            std::memcpy(h_pool + static_cast<size_t>(s) * slot_bytes + kPayloadOffset,
                        poison.data(), npts * sizeof(float));

    CuFFTExecutor fft(npts, own_stream);
    cufftComplex* d_out = nullptr;
    CUDA_OK(cudaMalloc(&d_out, sizeof(cufftComplex) * (npts / 2 + 1)));

    cudaEvent_t consumed;
    CUDA_OK(cudaEventCreateWithFlags(&consumed, cudaEventDisableTiming));

    // The external arm has nothing left to allocate, so it can freeze here.
    // The stock arm cannot: it has not seen the library's buffers yet, and
    // registering them is the one startup cost it is entitled to. It freezes
    // after the warmup below.
    if (!stock) guard::freeze();

    // ── connect ──────────────────────────────────────────────────────────
    std::printf("\nwaiting for the sender on %s:%u ...\n", addr.c_str(), port);
    std::fflush(stdout);

    GrpcDirectServer* srv =
        stock ? grpc_direct_server_create("extbuf_fft",
                                          GRPC_DIRECT_TRANSPORT_RDMA,
                                          addr.c_str(), port)
              : grpc_direct_server_create_ext("extbuf_fft",
                                              GRPC_DIRECT_TRANSPORT_RDMA,
                                              addr.c_str(), port,
                                              h_pool, pool_bytes, slot_bytes);
    if (!srv) {
        std::fprintf(stderr, "FATAL: server create returned NULL (arm=%s)\n",
                     stock ? "stock" : "ext");
        return 2;
    }
    std::printf("connected\n\n");

    // ── warmup: unmeasured, and it does two separate jobs ────────────────
    // One, it ramps the GPU. Sampling clocks.sm once a second across a run
    // gave 208 208 208 2405 2405 2405 2405 2457 2405 234 208 208: the part
    // needs about three seconds of sustained load to leave idle clocks and
    // drops back within one second of the load stopping. A 500 message run at
    // 16 KB finishes long before that, which is how a cuFFT p50 of 21.25 us
    // got recorded against a true 7.62 us. Nothing can leave the clock up
    // between runs, so the ramp has to happen inside this process, driven by
    // the same traffic that will be measured.
    //
    // Two, in the stock arm it is where every library slot gets seen and
    // registered, since after the freeze below registering a new one aborts.
    //
    // GRPC_DIRECT_TRANSPORT_RDMA rather than RDMA_LOW_LATENCY, so RX polling
    // is off. That is deliberate and is why the arm is named nopoll: our path
    // cannot poll with external buffers, so a polling stock arm would confound
    // allocation ownership with wakeup mechanism and answer neither question.
    const int warm_n = stock ? (warmup > reg_warmup ? warmup : reg_warmup)
                             : warmup;
    if (warm_n > 0) {
        std::printf("warmup: %d unmeasured messages\n", warm_n);
        for (int m = 0; m < warm_n; ++m) {
            const uint8_t* p    = nullptr;
            size_t         n    = 0;
            size_t         wslot = 0;
            GrpcDirectActiveRequest* a =
                stock ? grpc_direct_server_receive(srv, &p, &n)
                      : grpc_direct_server_receive_ext(srv, &p, &n, &wslot);
            if (!a) {
                std::fprintf(stderr, "FATAL: warmup receive failed at %d of %d\n",
                             m, warm_n);
                return 2;
            }
            const unsigned char* dp =
                stock ? stock_device_ptr(reinterpret_cast<const unsigned char*>(p), n)
                      : d_pool + wslot * slot_bytes;
            fft.execute(reinterpret_cast<const float*>(dp + kPayloadOffset), d_out);
            CUDA_OK(cudaEventRecord(consumed, fft.stream()));
            CUDA_OK(cudaEventSynchronize(consumed));
            grpc_direct_request_destroy(a);
            if (!stock) grpc_direct_server_slot_requeue(srv, wslot);
        }
        if (stock) {
            std::printf("registered %zu distinct regions during warmup\n",
                        g_regs.size());
            if (g_regs.size() < 2)
                std::fprintf(stderr,
                             "WARNING: only %zu region(s) seen. If a later message "
                             "lands somewhere new the guard will abort, which is "
                             "correct but wastes a run. Raise --reg-warmup.\n",
                             g_regs.size());
        }
        std::printf("\n");
    } else if (stock) {
        std::fprintf(stderr,
                     "FATAL: the stock arm cannot run with no warmup. Every "
                     "library slot has to be registered before the guard "
                     "freezes.\n");
        return 2;
    }
    if (stock) guard::freeze();
    const uint64_t frozen_allocs = guard::allocs, frozen_xlates = guard::xlates,
                   frozen_regs = guard::regs;

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
            stock ? grpc_direct_server_receive(srv, &ptr, &len)
                  : grpc_direct_server_receive_ext(srv, &ptr, &len, &slot);
        if (!ar) {
            std::fprintf(stderr, "receive returned NULL after %llu messages "
                                 "(sender gone, or a completion reported an error)\n",
                         (unsigned long long)received);
            break;
        }
        const double t0 = now_us();
        ++received;

        const unsigned char* d_slot = nullptr;
        if (stock) {
            // No pool of ours to check against. The registration table is the
            // check instead: a pointer outside every region we registered
            // during warmup aborts inside stock_device_ptr, because the guard
            // has frozen and it is not allowed to register a new one.
            d_slot = stock_device_ptr(reinterpret_cast<const unsigned char*>(ptr), len);
        } else {
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
            d_slot = d_pool + slot * slot_bytes;
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
            reinterpret_cast<const float*>(d_slot + kPayloadOffset);
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

        // Poisoning writes through the same mapping the NIC will reuse, in
        // both arms. The stock arm has no slot index, so the pointer we were
        // handed is the only address available, which is fine because the
        // library will not reuse it until the next receive releases it.
        if (poison_on)
            std::memcpy(const_cast<uint8_t*>(ptr) + kPayloadOffset,
                        poison.data(), npts * sizeof(float));

        if (csv)
            std::fprintf(csv, "%u,%zu,%zu,%d,%.3f,%.3f,%.1f,%.1f,%d,%s\n",
                         seq, slot, len, npts, t1 - t0, fft.last_exec_us(),
                         peak_hz, expect_hz, ok ? 1 : 0, git_sha.c_str());

        grpc_direct_request_destroy(ar);

        // Hand the slot back. After this instruction the NIC may overwrite it.
        //
        // The stock arm has no equivalent and that asymmetry is the arm. Its
        // slot is released at the top of the next receive, by the library, on
        // a schedule we do not control and cannot gate on a CUDA event. That
        // is safe here only because execute() blocks, which is exactly the
        // hazard step 6 is about.
        if (!stock) {
            const int32_t rq = grpc_direct_server_slot_requeue(srv, slot);
            if (rq != 0) {
                std::fprintf(stderr, "\nFATAL: slot_requeue(%zu) -> %d\n", slot, rq);
                std::abort();
            }
        }

        if (guard::allocs != frozen_allocs || guard::xlates != frozen_xlates ||
            guard::regs != frozen_regs) {
            std::fprintf(stderr, "\nFATAL: the buffer set changed during the run\n");
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
    std::printf("arm               : %s\n", stock ? "rdma-stock-nopoll" : "rdma");
    std::printf("received          : %llu of %d\n", (unsigned long long)received, msgs);
    std::printf("verified          : %llu\n", (unsigned long long)verified);
    std::printf("bad spectrum      : %llu\n", (unsigned long long)bad_spectrum);
    std::printf("bad frame         : %llu\n", (unsigned long long)bad_frame);
    if (bad_spectrum)
        std::printf("worst peak        : %.0f Hz, expected %.0f\n",
                    worst_seen_hz, worst_expect_hz);
    std::printf("e2e p50 / p99     : %.2f / %.2f us  (post-arrival, %zu samples)\n",
                pct(0.50), pct(0.99), e2e.size());
    std::printf("pool operations   : %llu alloc, %llu translate, %llu register "
                "(unchanged since startup: %s)\n",
                (unsigned long long)guard::allocs, (unsigned long long)guard::xlates,
                (unsigned long long)guard::regs,
                (guard::allocs == frozen_allocs && guard::xlates == frozen_xlates &&
                 guard::regs == frozen_regs)
                    ? "YES" : "NO");

    const bool pass = received > 0 && bad_frame == 0 &&
                      (!verify_on || (bad_spectrum == 0 && verified == received));
    std::printf("\n%s\n", pass ? "ALL RECEIVED MESSAGES VERIFIED" : "FAILURES PRESENT");

    grpc_direct_server_shutdown(srv);
    grpc_direct_server_destroy(srv);
    cudaFree(d_out);
    cudaEventDestroy(consumed);
    if (h_pool) cudaFreeHost(h_pool);
    for (const auto& r : g_regs) cudaHostUnregister(r.host);

    std::printf("DONE_EXTBUF rc=%d\n", pass ? 0 : 1);
    return pass ? 0 : 1;
}
