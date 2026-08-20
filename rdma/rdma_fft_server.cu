// rdma_fft_server.cu — Phase 2 receiver.  Runs on the Spark.
//
// WHAT THIS PROVES
// Bytes written by a remote NIC directly into a cudaHostAlloc'd buffer can be
// transformed in place by cuFFT and come out correct.  No gRPC, no iceoryx2,
// no protobuf.  The smallest program that exercises the architecture end to
// end so that Phase 3 has something known-good to integrate.
//
// THIS IS A CORRECTNESS HARNESS, NOT A BENCHMARK
// It runs in strict lockstep, one message in flight, with a TCP credit between
// messages.  That is deliberate: it makes the ordering deterministic, which is
// what lets the broken-ordering test below mean something.  Do not quote any
// timing out of this program.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE RACE THIS IS BUILT AROUND
//
// The CUDA GPUDirect documentation is explicit that only CPU-initiated CUDA
// APIs order these memory operations as the GPU observes them.  A kernel
// running concurrently with an in-flight RDMA write into the same memory may
// read stale, partial, or out-of-order data.  It is a data race, and its
// signature is not a crash: it is a plausible-looking spectrum computed on
// data that had not finished arriving.  That is the same failure class as the
// all-zero spectrum incident, with a subtler tell.
//
// So the rule the whole program is arranged around: THE THREAD THAT OBSERVES
// THE COMPLETION IS THE THREAD THAT LAUNCHES cuFFT, AND THE LAUNCH FOLLOWS THE
// OBSERVATION.  There is one thread here, and the two statements are adjacent
// and commented, so that any future edit that separates them is visible in a
// diff.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY --break-ordering EXISTS AND WHY IT RUNS FIRST
//
// A verification that always passes is indistinguishable from a verification
// that is not sensitive to what it claims to check.  Before trusting the green
// run, deliberately launch the transform BEFORE observing the completion and
// confirm the spectral check FAILS.  If it passes anyway, the checker cannot
// see the race, and every result built on top of it is unverified.
//
// Two things are needed to make that test capable of failing, and both are easy
// to leave out:
//
//   1. The payload changes every message.  The tone frequency is a function of
//      the sequence number.  If every message carried the same signal, reading
//      the previous message's bytes would verify clean and the race would be
//      invisible.
//   2. The slot is poisoned before each message.  Poison is a real tone at a
//      frequency the payload never uses, so "we transformed poison" reports as
//      a specific recognisable frequency rather than as a vague wrong answer.
//
// ─────────────────────────────────────────────────────────────────────────────
// HOT PATH DISCIPLINE
//
// Registration is expensive; the GPUDirect docs say so and prescribe caching.
// The pool is allocated, registered, and pointer-translated exactly once at
// startup.  This is not left to good intentions: after startup the counters are
// frozen, and any allocate, register, or translate call after that point aborts
// the program at the call site.  A per-message assertion re-checks the counts,
// so a call that somehow bypassed the wrappers still gets caught.
//
// Build: part of the CMake tree, target rdma_fft_server.

#include "cufft_executor.h"
#include "rdma_contract.h"
#include "rdma_link.h"
#include "signal_gen.h"

#include <cuda_runtime.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using namespace rdma;
using contract::Credit;
using contract::kPoisonToneHz;
using contract::kSampleRateHz;
using contract::payload_tone_hz;

// ─────────────────────────────────────────────────────────────────────────────
// Hot path guard
// ─────────────────────────────────────────────────────────────────────────────
namespace guard {
static bool     frozen = false;
static uint64_t allocs = 0, regs = 0, xlates = 0;

static void account(uint64_t& counter, const char* what) {
    if (frozen) {
        std::fprintf(stderr,
                     "\nFATAL: %s was called after startup.\n"
                     "The pool is supposed to be allocated, registered and "
                     "translated exactly once.\n"
                     "Doing any of it per message is the easiest way to build "
                     "something slower than what we already have.\n",
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

static ibv_mr* pool_reg_mr(ibv_pd* pd, void* addr, size_t bytes) {
    guard::account(guard::regs, "ibv_reg_mr");
    errno = 0;
    ibv_mr* mr = ibv_reg_mr(pd, addr, bytes,
                            IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
                                IBV_ACCESS_REMOTE_READ);
    if (!mr) die("ibv_reg_mr over the cudaHostAlloc pool");
    return mr;
}

static float* pool_device_ptr(void* host) {
    guard::account(guard::xlates, "cudaHostGetDevicePointer");
    void* d = nullptr;
    CUDA_OK(cudaHostGetDevicePointer(&d, host, 0));
    return static_cast<float*>(d);
}

// ─────────────────────────────────────────────────────────────────────────────
// Completion polling
// ─────────────────────────────────────────────────────────────────────────────
struct PollResult {
    bool     ok      = false;
    bool     timeout = false;
    uint32_t imm     = 0;
};

static PollResult poll_one(ibv_cq* cq, int timeout_ms, uint64_t& cq_errors) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    ibv_wc wc{};
    for (;;) {
        int n = ibv_poll_cq(cq, 1, &wc);
        if (n < 0) die("ibv_poll_cq");
        if (n > 0) {
            if (wc.status != IBV_WC_SUCCESS) {
                ++cq_errors;
                std::fprintf(stderr, "  completion error: %s (opcode %d)\n",
                             wc_status(wc.status), static_cast<int>(wc.opcode));
                return {};
            }
            return {true, false, ntohl(wc.imm_data)};
        }
        if (std::chrono::steady_clock::now() > deadline) return {false, true, 0};
    }
}

static void post_recv(ibv_qp* qp, uint64_t id) {
    ibv_recv_wr wr{}, *bad = nullptr;
    wr.wr_id   = id;
    wr.sg_list = nullptr;  // RDMA WRITE WITH IMM consumes the WR but no buffer
    wr.num_sge = 0;
    if (ibv_post_recv(qp, &wr, &bad)) die("ibv_post_recv");
}

// ─────────────────────────────────────────────────────────────────────────────
int main(int argc, char** argv) {
    const char* dev        = "rocep1s0f0";
    const char* peer_ip    = "192.168.20.2";  // the PXI, for GID selection
    int         gid_index  = -1;  // <0 = read it; see find_roce_v2_ipv4_gid
    int         tcp_port   = 18600;
    int         n_slots    = 4;
    int         msgs       = 200;
    int         tol_bins   = 3;
    bool        break_order = false;
    std::vector<int> sizes_kb{16, 32, 64, 128, 256, 512, 1024, 2048, 4096};

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> const char* {
            if (i + 1 >= argc) die_msg("missing value for an option");
            return argv[++i];
        };
        if (a == "--dev")                  dev = next();
        else if (a == "--gid")             gid_index = std::atoi(next());
        else if (a == "--peer")            peer_ip = next();
        else if (a == "--port")            tcp_port = std::atoi(next());
        else if (a == "--slots")           n_slots = std::atoi(next());
        else if (a == "--msgs")            msgs = std::atoi(next());
        else if (a == "--tol-bins")        tol_bins = std::atoi(next());
        else if (a == "--break-ordering")  break_order = true;
        else if (a == "--sizes-kb") {
            sizes_kb.clear();
            std::string s = next();
            size_t p = 0;
            while (p <= s.size()) {
                size_t c = s.find(',', p);
                if (c == std::string::npos) c = s.size();
                if (c > p) sizes_kb.push_back(std::atoi(s.substr(p, c - p).c_str()));
                p = c + 1;
            }
        } else {
            std::fprintf(stderr, "unknown option: %s\n", a.c_str());
            return 2;
        }
    }
    RDMA_CHECK(!sizes_kb.empty(), "no sizes given");
    RDMA_CHECK(n_slots >= 1, "--slots must be at least 1");

    std::sort(sizes_kb.begin(), sizes_kb.end());
    const size_t slot_bytes =
        static_cast<size_t>(sizes_kb.back()) * 1024u;
    const int n_max = static_cast<int>(slot_bytes / sizeof(float));

    std::printf("=== Phase 2: RDMA straight into cudaHostAlloc memory ===\n");
    std::printf("mode              : %s\n",
                break_order ? "*** BROKEN ORDERING (this run is SUPPOSED to fail) ***"
                            : "correct ordering");
    std::printf("sizes (KB)        : ");
    for (size_t i = 0; i < sizes_kb.size(); ++i)
        std::printf("%d%s", sizes_kb[i], i + 1 < sizes_kb.size() ? "," : "\n");
    std::printf("messages per size : %d\n", msgs);

    // ── startup: device, QP ──────────────────────────────────────────────
    Endpoint ep;
    ep.gid_index = gid_index;
    ep.peer_ip   = peer_ip;  // pick the local GID that can reach the sender
    ep.ctx       = open_device(dev);
    ep.psn       = 0x1234;
    create_qp(ep, 2 * n_slots + 16, 16, 2 * n_slots + 16);

    // ── startup: the receive pool.  Once.  ───────────────────────────────
    const size_t pool_bytes = slot_bytes * static_cast<size_t>(n_slots);
    auto*        pool       = static_cast<uint8_t*>(pool_host_alloc(pool_bytes));
    ibv_mr*      mr         = pool_reg_mr(ep.pd, pool, pool_bytes);

    std::vector<float*> h_slot(n_slots), d_slot(n_slots);
    for (int s = 0; s < n_slots; ++s) {
        h_slot[s] = reinterpret_cast<float*>(pool + static_cast<size_t>(s) * slot_bytes);
        d_slot[s] = pool_device_ptr(h_slot[s]);
    }

    std::printf("pool              : %d slots x %zu KB = %zu MB at %p\n",
                n_slots, slot_bytes / 1024, pool_bytes >> 20,
                static_cast<void*>(pool));
    std::printf("ibv_reg_mr        : lkey=0x%08x rkey=0x%08x\n", mr->lkey, mr->rkey);
    std::printf("host == device VA : %s\n",
                (static_cast<void*>(h_slot[0]) == static_cast<void*>(d_slot[0]))
                    ? "yes (C2C coherent, translation is an identity here)"
                    : "no (cached translation is doing real work)");

    // ── startup: every cuFFT plan, and the output buffer, up front ───────
    std::vector<CuFFTExecutor*> plans(sizes_kb.size(), nullptr);
    for (size_t i = 0; i < sizes_kb.size(); ++i)
        plans[i] = new CuFFTExecutor(static_cast<int>(
            static_cast<size_t>(sizes_kb[i]) * 1024u / sizeof(float)));

    cufftComplex* d_out = nullptr;
    CUDA_OK(cudaMalloc(&d_out, sizeof(cufftComplex) * (n_max / 2 + 1)));

    // ── startup: the poison pattern, generated once ──────────────────────
    SignalConfig poison_cfg;
    poison_cfg.sample_rate_hz = kSampleRateHz;
    poison_cfg.buffer_size    = n_max;
    poison_cfg.freqs_hz       = {kPoisonToneHz};
    poison_cfg.amplitudes     = {1.0f};
    std::vector<float> poison(n_max);
    generate_signal(poison_cfg, poison.data(), n_max);

    // ── the hot path starts here and may not allocate anything ───────────
    guard::freeze();
    const uint64_t frozen_allocs = guard::allocs;
    const uint64_t frozen_regs   = guard::regs;
    const uint64_t frozen_xlates = guard::xlates;
    std::printf("startup complete  : %llu alloc, %llu reg_mr, %llu translate; "
                "counters now frozen\n\n",
                static_cast<unsigned long long>(frozen_allocs),
                static_cast<unsigned long long>(frozen_regs),
                static_cast<unsigned long long>(frozen_xlates));

    // ── connect ──────────────────────────────────────────────────────────
    int fd = tcp_listen_accept(tcp_port);

    WireInfo mine{};
    mine.qpn        = ep.qp->qp_num;
    mine.psn        = ep.psn;
    mine.rkey       = mr->rkey;
    mine.n_slots    = static_cast<uint32_t>(n_slots);
    mine.pool_addr  = reinterpret_cast<uint64_t>(pool);
    mine.slot_bytes = slot_bytes;
    std::memcpy(mine.gid, ep.gid.raw, 16);

    WireInfo peer = exchange(fd, mine);
    connect_qp(ep, peer, IBV_MTU_4096);
    std::printf("\n");

    // ── the sweep ────────────────────────────────────────────────────────
    uint64_t total_msgs = 0, total_bad = 0, total_timeouts = 0, cq_errors = 0;
    bool     any_size_failed = false;

    std::printf("%8s %10s %10s %10s   %s\n",
                "size KB", "messages", "verified", "failed", "worst peak seen");
    std::printf("%s\n", std::string(74, '-').c_str());

    for (size_t si = 0; si < sizes_kb.size(); ++si) {
        const int    kb        = sizes_kb[si];
        const size_t bytes     = static_cast<size_t>(kb) * 1024u;
        const int    n_samples = static_cast<int>(bytes / sizeof(float));
        const float  bin_hz    = kSampleRateHz / static_cast<float>(n_samples);
        const float  tol_hz    = bin_hz * static_cast<float>(tol_bins);

        uint64_t good = 0, bad = 0;
        float    worst_err_hz = 0.0f, worst_seen_hz = 0.0f, worst_expect_hz = 0.0f;

        for (int m = 0; m < msgs; ++m) {
            const uint32_t seq  = static_cast<uint32_t>(m);
            const int      slot = m % n_slots;

            // 1. Poison the slot.  Without this, the previous message's bytes
            //    are still sitting there and a broken-ordering run could verify
            //    clean by reading them.
            std::memcpy(h_slot[slot], poison.data(), bytes);

            // 2. Post the receive that will carry the sender's immediate.
            post_recv(ep.qp, static_cast<uint64_t>(seq));

            // 3. Release the sender.
            Credit c{seq, static_cast<uint32_t>(slot),
                     static_cast<uint32_t>(n_samples), 0,
                     static_cast<uint64_t>(slot) * slot_bytes};
            send_all(fd, &c, sizeof(c));

            PollResult pr;
            if (break_order) {
                // ── DELIBERATELY WRONG ──────────────────────────────────
                // Launch the transform while the RDMA write is still in
                // flight.  If the verification below still passes, the
                // verification is not sensitive to the race and nothing built
                // on it is trustworthy.
                plans[si]->execute(d_slot[slot], d_out);
                pr = poll_one(ep.cq, 5000, cq_errors);  // drain afterwards
            } else {
                // ── THE ORDERING RULE ───────────────────────────────────
                // Observe the completion...
                pr = poll_one(ep.cq, 5000, cq_errors);
                // ...then, on this same thread, launch the transform.  These
                // two statements must stay adjacent and in this order.
                if (pr.ok) plans[si]->execute(d_slot[slot], d_out);
            }

            if (pr.timeout) {
                ++total_timeouts;
                std::fprintf(stderr, "  timed out waiting for seq %u at %d KB\n",
                             seq, kb);
                break;
            }
            if (!pr.ok && !break_order) { ++bad; continue; }

            // 4. Verify.  The expected tone is a function of the sequence
            //    number, so reading a stale slot fails just as loudly as
            //    reading poison.
            auto        peaks    = plans[si]->detect_peaks(d_out, 3, kSampleRateHz);
            const float expect   = payload_tone_hz(seq);
            const float seen     = peaks.empty() ? -1.0f : peaks[0].first;
            const float err      = std::fabs(seen - expect);

            if (err <= tol_hz) {
                ++good;
            } else {
                ++bad;
                if (err > worst_err_hz) {
                    worst_err_hz    = err;
                    worst_seen_hz   = seen;
                    worst_expect_hz = expect;
                }
            }
            ++total_msgs;

            // 5. The hot path allocated nothing.  Asserted, not assumed.
            if (guard::allocs != frozen_allocs || guard::regs != frozen_regs ||
                guard::xlates != frozen_xlates) {
                std::fprintf(stderr,
                             "\nFATAL: the pool changed during the run "
                             "(alloc %llu->%llu, reg %llu->%llu, xlate %llu->%llu)\n",
                             (unsigned long long)frozen_allocs,
                             (unsigned long long)guard::allocs,
                             (unsigned long long)frozen_regs,
                             (unsigned long long)guard::regs,
                             (unsigned long long)frozen_xlates,
                             (unsigned long long)guard::xlates);
                std::abort();
            }
        }

        total_bad += bad;
        if (bad) any_size_failed = true;

        char worst[64] = "-";
        if (bad)
            std::snprintf(worst, sizeof(worst), "%.0f Hz, expected %.0f",
                          worst_seen_hz, worst_expect_hz);
        std::printf("%8d %10d %10llu %10llu   %s\n", kb, msgs,
                    (unsigned long long)good, (unsigned long long)bad, worst);
        std::fflush(stdout);
    }

    // Tell the sender the run is over.
    Credit stop{0, 0, 0, 1, 0};
    send_all(fd, &stop, sizeof(stop));

    std::printf("\n");
    std::printf("verified          : %llu\n", (unsigned long long)(total_msgs - total_bad));
    std::printf("verification fails: %llu\n", (unsigned long long)total_bad);
    std::printf("completion errors : %llu\n", (unsigned long long)cq_errors);
    std::printf("timeouts          : %llu\n", (unsigned long long)total_timeouts);
    std::printf("pool operations   : %llu alloc, %llu reg_mr, %llu translate "
                "(unchanged since startup: %s)\n",
                (unsigned long long)guard::allocs,
                (unsigned long long)guard::regs,
                (unsigned long long)guard::xlates,
                (guard::allocs == frozen_allocs && guard::regs == frozen_regs &&
                 guard::xlates == frozen_xlates) ? "YES" : "NO");

    int rc;
    if (break_order) {
        // Inverted on purpose.  In this mode a clean run is the bad outcome:
        // it means the checker cannot see the race it exists to catch.
        if (any_size_failed) {
            std::printf("\nBROKEN-ORDERING TEST PASSED: the verification "
                        "noticed. It is sensitive to the race.\n");
            rc = 0;
        } else {
            std::printf("\n*** BROKEN-ORDERING TEST FAILED ***\n"
                        "The transform ran before the data had arrived and the "
                        "spectral check still passed.\n"
                        "The check is not sensitive to the race, so it cannot "
                        "certify the correct-ordering run either.\n"
                        "Strengthen the check before trusting anything built on "
                        "it.\n");
            rc = 1;
        }
    } else {
        rc = (total_bad == 0 && cq_errors == 0 && total_timeouts == 0) ? 0 : 1;
        std::printf("\n%s\n", rc == 0 ? "ALL SIZES VERIFIED" : "*** FAILURES, see above ***");
    }

    for (auto* p : plans) delete p;
    cudaFree(d_out);
    ibv_dereg_mr(mr);
    cudaFreeHost(pool);
    ::close(fd);
    std::printf("DONE_RDMA_FFT rc=%d\n", rc);
    return rc;
}
