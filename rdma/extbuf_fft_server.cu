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
// e2e_us IS NOT A PIPELINE LATENCY AND NEVER WAS.  It starts after the data has
// landed.  Two other numbers exist now because quoting it alone misled us for
// four weeks:
//
//   inter-arrival gap, printed by this program in streaming mode, on this box's
//   clock alone.  It is how often a buffer actually shows up, so it is what
//   bounds the pipeline.  At 4 MB it was 2205 us against a 685 us wire time
//   while e2e was 72 us.
//
//   the echo round trip, printed by the sender with --echo on, on the sender's
//   clock alone.  It is post-to-transform-complete and it is the number a
//   system integrator asks for.  It cannot be measured by differencing the two
//   boxes' clocks: they are 23.13 seconds apart and neither runs NTP.
//
// The two are instruments for different quantities and come from different
// runs, because --echo on serialises the sender.  Do not put them in the same
// table row.
//
// Throughput and inter-message gap are NOT quotable with --poison on or
// --verify every.  The program WITHHOLDS those lines in either case rather than
// printing them with a caveat, because a number that is not printed cannot be
// lifted out of a log four weeks later.
//
// The reason is not the one this file gave for a month, and the difference
// matters.  The story was that these run before the re-queue, so they hold the
// sender's credit.  detect_peaks was moved below the re-queue to test that:
// hold_us fell from 2488 us to 1.5 us and the sustained rate did not move at
// all, 1611/1511/1576 MiB/s before and after.  So the credit window was never
// the mechanism.
//
// The mechanism is that this is one thread.  detect_peaks costs about 2400 us
// of it per message at 4 MiB, and the next receive_ext cannot be called until
// it returns, so the arrival interval is the consumer's loop time no matter
// where in that loop the work sits.  Four slots of buffering do not help,
// because the producer is not bursty: it is continuous and we are slower than
// it.  Moving work out of the credit window only helps if something else can
// use the thread, and here nothing can.
//
// The move was kept anyway.  It costs nothing, and hold_us is now an honest
// measure of the credit window instead of a measure of whatever we left in it.
//
// The general form, which is the part worth carrying to another project: in any
// pipeline where the consumer owns buffer lifetime, measure gate-to-credit-
// returned as a first-class column.  It is hold_us here.  Then check it against
// the arrival interval before concluding anything, because a large hold_us and
// a slow consumer look identical from the sender's side.  Both show up as time
// blocked in AcquireSendRegion.  Only the receiver can tell them apart.
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

// Send the echo acknowledgement.  CONSUMES ar, exactly like the underlying
// grpc_direct_server_send, so the caller must not destroy it afterwards.
//
// The response travels on the tx_session the library opened on port+1 at accept
// time.  That session is ordinary internally-buffered easyrdma, not the external
// pool: the pool is a receive-side arrangement and there is nothing to gain from
// applying it to sixteen bytes.
static bool echo_ack(GrpcDirectActiveRequest* ar, uint32_t seq, int npts,
                     bool fft_ran) {
    contract::EchoAck ack;
    ack.magic     = contract::kEchoMagic;
    ack.seq       = seq;
    ack.n_samples = static_cast<uint32_t>(npts);
    ack.flags     = fft_ran ? contract::kEchoFlagFft : 0u;
    return grpc_direct_server_send(ar, reinterpret_cast<const uint8_t*>(&ack),
                                   sizeof(ack)) == 0;
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
        "  --poison  on|off   repaint each slot before re-queueing (default on).\n"
        "                  The only thing left in the credit window. With this\n"
        "                  on, or with --verify every, the inter-arrival and\n"
        "                  sustained-rate lines are WITHHELD from the report\n"
        "                  rather than printed with a caveat.\n"
        "  --verify  every|off  spectral check per message (default every).\n"
        "                  Runs AFTER the slot re-queue, so hold_us stays near\n"
        "                  zero, but it still costs ~2400 us of the consumer\n"
        "                  thread at 4 MiB and the next receive waits on it.\n"
        "                  With this on the rate lines are WITHHELD.\n"
        "  --own-stream    run cuFFT on its own stream\n"
        "  --tol-bins N    peak tolerance in bins (default 2)\n"
        "  --stock         rdma-stock-nopoll arm: driver-allocated buffers,\n"
        "                  registered once during warmup instead of a pool we\n"
        "                  own. No re-queue; the library owns slot lifetime.\n"
        "  --reg-warmup N  unmeasured messages before timing, used to see and\n"
        "                  register every stock slot (default 32)\n"
        "  --echo    on|off   send a 16-byte ack after the transform completes,\n"
        "                  so the sender can time post-to-FFT-complete on its\n"
        "                  own clock (default off). Serialises the pipeline:\n"
        "                  this is the latency instrument, not the throughput\n"
        "                  one. Requires --poison off.\n"
        "  --fft     on|off   run the transform (default on). Off is the echo\n"
        "                  calibration arm: with a tiny --npts it measures the\n"
        "                  request-and-return path with no work in the middle,\n"
        "                  and that gets subtracted from the full run.\n"
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
    bool        echo_on = false, fft_on = true;

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
        else if (a == "--echo")       echo_on = (next() == "on");
        else if (a == "--fft")        fft_on = (next() != "off");
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

    // ── WHAT IS STILL INSIDE THE CREDIT WINDOW, AND WHAT LEFT IT ─────────────
    // Poisoning is a full payload memcpy through the mapping the NIC will reuse,
    // so it has to happen before the re-queue.  It is the only thing left there.
    //
    // Verifying used to be there too and did not need to be: detect_peaks reads
    // d_out, the transform's output in device memory, and never touches the
    // slot.  It now runs after the re-queue.  That was expected to be worth the
    // 3.18x the flag is worth.  It was worth nothing.  hold_us fell from 2488 us
    // to 1.5 us and the sustained rate did not move, 1611/1511/1576 MiB/s before
    // and after, because this is one thread and the next receive_ext waits for
    // detect_peaks wherever in the loop it sits.  Extra slots do not help: the
    // producer is not bursty, it is continuous and we are slower than it.  The
    // move is kept because it makes hold_us mean what it says.
    //
    // So both flags still cost throughput, for different reasons, and both
    // withhold the rate lines below.  Neither is refused outright: Phase 4 wants
    // the spectral check and quotes latency, not rate, and taking the check away
    // to protect a number it does not quote would be the wrong trade.
    //
    // --echo on with --poison on is refused, because there the contamination
    // does not surface as a rate anyone would think to distrust.  Echo mode has
    // no other traffic for a 4 MiB memcpy to hide behind, so poison delays the
    // next message rather than this one.  Verify is fine in echo mode now that
    // it is below the re-queue, which is below the ack, so it is outside the
    // interval the sender times.
    if (echo_on && poison_on) {
        std::fprintf(stderr,
                     "--echo on requires --poison off.\n"
                     "Poison is a full payload memcpy on the consumer thread. In "
                     "echo mode there is no other traffic to absorb it, so it "
                     "delays the next message rather than this one and the "
                     "contamination moves somewhere harder to see.\n"
                     "(--verify every is fine here: it moved below the re-queue, "
                     "which is below the ack, so it is outside the timed "
                     "interval.)\n");
        return 1;
    }
    // The other half of the same rule, and the one that would otherwise let a
    // driver script and this file disagree in silence again.  scripts/
    // phase4_cell.sh passed --verify every for a month while the comment in this
    // file said Phase 4 needed it off, and nothing caught it, because a comment
    // cannot refuse anything.  A withheld number can.
    const bool rate_is_reportable = !poison_on && !verify_on;
    if (!fft_on && !echo_on) {
        std::fprintf(stderr,
                     "--fft off is only meaningful with --echo on. On its own it "
                     "is a receiver that measures nothing.\n");
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
    std::printf("mode              : %s, transform %s\n",
                echo_on ? "echo (latency; sender is serialised)"
                        : "streaming (throughput)",
                fft_on ? "on" : "OFF (echo calibration, measures the paths only)");

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
            if (fft_on) {
                fft.execute(reinterpret_cast<const float*>(dp + kPayloadOffset), d_out);
                CUDA_OK(cudaEventRecord(consumed, fft.stream()));
                CUDA_OK(cudaEventSynchronize(consumed));
            }
            // The warmup has to ack too.  In echo mode the sender blocks on a
            // reply for every message including the warmup ones, so a warmup
            // that stayed silent would deadlock on message zero and look like a
            // fabric problem.
            if (echo_on) {
                const auto* wh = reinterpret_cast<const ExtFrameHeader*>(p);
                if (!echo_ack(a, wh->seq, npts, fft_on)) {
                    std::fprintf(stderr, "FATAL: warmup ack failed at %d\n", m);
                    return 2;
                }
            } else {
                grpc_direct_request_destroy(a);
            }
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
        // gap_us goes after ok rather than at the end, so that the existing
        // field positions the Phase 4 script cuts on (5, 6 and 9) do not move.
        std::fprintf(csv,
                     "seq,slot,bytes,npts,e2e_us,fft_us,peak_hz,expect_hz,ok,"
                     "gap_us,gitsha\n");
    }

    // ── the loop ─────────────────────────────────────────────────────────
    const float bin_hz = kSampleRateHz / static_cast<float>(npts);
    const float tol_hz = bin_hz * static_cast<float>(tol_bins);

    uint64_t received = 0, verified = 0, bad_spectrum = 0, bad_frame = 0;
    float    worst_err_hz = 0.0f, worst_seen_hz = 0.0f, worst_expect_hz = 0.0f;
    std::vector<double> e2e;
    e2e.reserve(msgs);

    // Inter-arrival, measured on this box's clock only.
    //
    // This is the cadence the consumer actually sees, and it is the number the
    // whole pipeline is bounded by. e2e says how long the work takes once a
    // buffer is in hand; this says how often a buffer arrives. The first is
    // useless without the second, and reporting only the first is how a 72 us
    // post-arrival figure got quoted for a path whose buffers arrive every
    // 2205 us.
    //
    // Taken after receive_ext returns, so it is arrival-to-arrival as observed,
    // not as posted. In streaming mode it is the reciprocal of throughput. In
    // echo mode it is meaningless, because the sender is waiting for us.
    std::vector<double> gap;
    gap.reserve(msgs);
    double t_prev = 0.0;

    // Credit return, also on this box's clock.
    //
    // hold_us is from the transform's gate completing to the re-queue call
    // returning, which is how long the NIC waits for a slot it could already
    // have had. rq_us is the re-queue call itself. If the sender is blocked
    // 2205 us per buffer and hold_us is large, the receiver is the reason and
    // the fix is on this side. If hold_us is near zero, it is not, and the
    // question moves to the sender's two host copies or to the depth of the
    // slot pool.
    //
    // Both are outside e2e and always will be: e2e stops at the gate.
    std::vector<double> hold, rq_us;
    hold.reserve(msgs);
    rq_us.reserve(msgs);

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
        if (t_prev > 0.0) gap.push_back(t0 - t_prev);
        t_prev = t0;
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
        if (frame_ok && fft_on) fft.execute(d_payload, d_out);

        // ── THE GATE ─────────────────────────────────────────────────────
        // Nothing below may touch the slot until this event has completed, and
        // the re-queue below hands the slot to the NIC.  Currently redundant
        // because execute() blocks; see the header comment for why it is here.
        if (fft_on) {
            CUDA_OK(cudaEventRecord(consumed, fft.stream()));
            CUDA_OK(cudaEventSynchronize(consumed));
        }

        const double t1 = now_us();
        e2e.push_back(t1 - t0);

        // ── THE ACK ──────────────────────────────────────────────────────
        // Immediately after the gate and before anything else, because
        // everything else is harness. The sender's clock stops when this
        // arrives, so any instruction placed above this line is charged to the
        // transport in the headline number.
        //
        // This consumes ar. The verify, poison and re-queue below still run,
        // and still delay the sender's credit, but they now do so while the ack
        // is already in flight rather than before it leaves. In the sanctioned
        // echo configuration verify and poison are both refused at startup, so
        // what is left between here and the re-queue is a CSV line.
        if (echo_on) {
            if (!echo_ack(ar, seq, npts, fft_on && frame_ok)) {
                std::fprintf(stderr, "\nFATAL: echo ack failed at seq %u\n", seq);
                std::abort();
            }
            ar = nullptr;
        }

        // ── WHAT IS ALLOWED TO STAND HERE, AND WHY IT IS ALMOST NOTHING ──
        // Everything between the gate above and the re-queue below is time the
        // NIC spends waiting for a slot it could already have had, and the
        // sender pays it inside AcquireSendRegion and reports it as send time.
        // hold_us measures exactly this interval, which is the only way to tell
        // it apart from a slow consumer: both look like blocked send time from
        // the other box.
        //
        // The test for whether something belongs here is whether it touches the
        // slot. Poison does, because it writes through the mapping the NIC will
        // reuse, so it has no choice. The spectral check does not: it reads
        // d_out, cudaMalloc'd device memory holding the transform's output. So
        // the check moved below the re-queue, and hold_us went from 2488 us to
        // 1.5 us.
        //
        // The rate did not move. That is the useful part. Being out of the
        // credit window does not help when there is one consumer thread and the
        // next receive_ext is behind the same work. The move is still right,
        // because now hold_us reports the credit window rather than reporting
        // whatever we happened to leave in it.
        if (poison_on)
            std::memcpy(const_cast<uint8_t*>(ptr) + kPayloadOffset,
                        poison.data(), npts * sizeof(float));

        if (ar) grpc_direct_request_destroy(ar);

        // Hand the slot back. After this instruction the NIC may overwrite it.
        //
        // The stock arm has no equivalent and that asymmetry is the arm. Its
        // slot is released at the top of the next receive, by the library, on
        // a schedule we do not control and cannot gate on a CUDA event. That
        // is safe here only because execute() blocks, which is exactly the
        // hazard step 6 is about.
        if (!stock) {
            const double r0 = now_us();
            const int32_t rq = grpc_direct_server_slot_requeue(srv, slot);
            const double r1 = now_us();
            if (rq != 0) {
                std::fprintf(stderr, "\nFATAL: slot_requeue(%zu) -> %d\n", slot, rq);
                std::abort();
            }
            rq_us.push_back(r1 - r0);
            hold.push_back(r1 - t1);
        }

        // ── VERIFICATION, DELIBERATELY BELOW THE RE-QUEUE ────────────────
        // The NIC may already be refilling the slot. That is fine: this reads
        // d_out, the transform's output in device memory, and never touches the
        // slot.
        //
        // It costs about 2400 us of this thread per message at 4 MiB, and the
        // next receive_ext is behind it, so it still sets the arrival rate. That
        // is why the rate lines are withheld when it is on. Being below the
        // re-queue makes hold_us honest; it does not make this cheap.
        float peak_hz = -1.0f, expect_hz = payload_tone_hz(seq);
        bool  ok = frame_ok;
        if (frame_ok && verify_on && fft_on) {
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

        if (csv)
            std::fprintf(csv, "%u,%zu,%zu,%d,%.3f,%.3f,%.1f,%.1f,%d,%.3f,%s\n",
                         seq, slot, len, npts, t1 - t0, fft.last_exec_us(),
                         peak_hz, expect_hz, ok ? 1 : 0,
                         gap.empty() ? 0.0 : gap.back(), git_sha.c_str());

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

    // Inter-arrival and the rate it implies.
    //
    // Printed next to e2e deliberately, so that the two are read together. A
    // consumer that finishes in 72 us and is handed a buffer every 2205 us is
    // idle 97% of the time, and no amount of work on the 72 us changes that.
    // The duty cycle is spelled out rather than left as an exercise.
    std::sort(gap.begin(), gap.end());
    auto gpct = [&](double p) {
        if (gap.empty()) return 0.0;
        return gap[static_cast<size_t>(p * (gap.size() - 1))];
    };
    const double g50 = gpct(0.50);
    if (echo_on) {
        std::printf("inter-arrival     : not meaningful with --echo on "
                    "(the sender is waiting for us)\n");
    } else if (!rate_is_reportable) {
        std::printf("inter-arrival     : WITHHELD.%s%s\n"
                    "                    Either one costs this thread more per "
                    "message than the wire time, and\n"
                    "                    the next receive waits on it, so the "
                    "rate below would be measuring\n"
                    "                    this harness and not the transport. "
                    "Measured: 1576 MiB/s with\n"
                    "                    --verify every against 4989 without, "
                    "same run, same rep.\n"
                    "                    Re-run with both off. handoff.md 7i.\n",
                    poison_on ? " --poison on." : "",
                    verify_on ? " --verify every." : "");
    } else if (g50 > 0.0) {
        const double mib_s = static_cast<double>(frame_bytes) / g50
                             * 1e6 / (1024.0 * 1024.0);
        std::printf("inter-arrival     : %.2f / %.2f us p50/p99  (%zu samples)\n",
                    g50, gpct(0.99), gap.size());
        std::printf("sustained rate    : %.0f MiB/s of %zu-byte frames\n",
                    mib_s, frame_bytes);
        std::printf("consumer duty     : %.1f%%  (e2e p50 %.2f us of a %.2f us "
                    "arrival interval)\n",
                    100.0 * pct(0.50) / g50, pct(0.50), g50);
    }
    if (!hold.empty()) {
        std::sort(hold.begin(), hold.end());
        std::sort(rq_us.begin(), rq_us.end());
        auto hp = [&](std::vector<double>& v, double p) {
            return v[static_cast<size_t>(p * (v.size() - 1))];
        };
        std::printf("credit return     : %.2f us p50 gate-to-requeued, "
                    "%.2f us p50 in the requeue call itself\n",
                    hp(hold, 0.50), hp(rq_us, 0.50));
    }
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
