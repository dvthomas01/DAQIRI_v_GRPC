// Why is extbuf's 4 MiB transform ~14 us slower than DAQiri's on the same rung?
//
// Table B (handoff 7n) put base at 47.78 us from device memory and daq 64.13,
// opt 64.99 and extbuf 78.40 from pinned host memory, all in one rotation. opt
// and daq agreeing to 0.9 us is what says the memory-class ladder is real, and
// it leaves extbuf 14 us off a rung it should be sitting on. 7o named two
// candidates. This program tests the second and re-tests the first.
//
// Candidate 1, the stream mode, is already dead by code reading:
// extbuf_fft_server.cu:315 defaults own_stream=false and only --own-stream sets
// it, which the Table B arm never passed. So both arms ran the same stream mode.
// It is re-tested here anyway because it cost one flag to do, and a candidate
// killed by reading is weaker than one killed by measurement.
//
// Candidate 2 was "slot geometry", which is really two hypotheses:
//   extbuf_fft_server.cu:404 rounds slot_bytes up to a multiple of 256, not to a
//   page or a 2 MB boundary. At 4 MiB that is 4194560, so with a 2 MB aligned
//   pool the four payloads land 256, 512, 768 and 1024 bytes past a 2 MB
//   boundary and not one of them is page aligned.
//   Separately, extbuf cycles across four slots spanning 16 MB of pool, while
//   every isolated benchmark so far re-transformed one resident buffer.
// Those are different mechanisms and a single "slot geometry" arm would confound
// them, so the arms below separate them:
//
//   single   one buffer, payload at +256           control, this is ha_off
//   cycle    4 slots x 4194560, payload at +256    extbuf exactly
//   pad2m    4 slots padded to 2 MB, payload +256  cycling, stride realigned
//   cycle0   4 slots x 4194560, payload at +0      cycling, offset removed
//
// single vs cycle isolates the working set. cycle vs pad2m isolates the stride.
// cycle vs cycle0 isolates the offset under cycling, which is the case ha_off
// never covered because it only ever tested one buffer at one offset.
//
// Arms are rotated within each rep. Every arm writes its payload from the CPU
// before transforming, because a read-only ladder is what made the memory-kind
// result wrong once already, and because in the real path the NIC has just
// written the buffer. Correctness is checked before any timing is kept.
//
// build on the Spark:
//   nvcc -O2 -arch=native -std=c++17 -I. -I../common -I../fft \
//        rdma/slotgeom_probe.cu fft/cufft_executor.cu common/signal_gen.cc \
//        -lcufft -o /tmp/slotgeom_probe
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
#include "cufft_executor.h"
#include "signal_gen.h"

#define CUDA_OK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) {          \
    std::fprintf(stderr, "CUDA %s at %d: %s\n", #x, __LINE__,                   \
                 cudaGetErrorString(e_)); std::exit(1); } } while (0)

static const size_t kOff      = 256;      // contract::kPayloadOffset
static const int    kSlots    = 4;        // --slots default in the server
static const double kRateHz   = 1.0e6;

struct Arm {
    const char*    name;
    int            slots;
    size_t         stride;     // bytes between slot bases
    size_t         offset;     // payload offset within a slot
    unsigned char* h_pool;
    unsigned char* d_pool;
};

static double median(std::vector<double> v) {
    if (v.empty()) return 0.0;
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);   // an abort must not eat the output

    int    npts       = 1048576;           // 4 MiB payload, the size in question
    int    reps       = 5;
    int    iters      = 40;
    int    warmup     = 200;
    bool   own_stream = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() { return argv[++i]; };
        if      (a == "--npts")       npts       = std::atoi(next());
        else if (a == "--reps")       reps       = std::atoi(next());
        else if (a == "--iters")      iters      = std::atoi(next());
        else if (a == "--warmup")     warmup     = std::atoi(next());
        else if (a == "--own-stream") own_stream = true;
        else { std::fprintf(stderr, "unknown flag %s\n", a.c_str()); return 2; }
    }

    const size_t payload   = static_cast<size_t>(npts) * sizeof(float);
    const size_t frame     = payload + kOff;
    const size_t stride256 = ((frame + kOff - 1) / kOff) * kOff;          // the server's rule
    const size_t k2m       = 2u << 20;
    const size_t stride2m  = ((frame + k2m - 1) / k2m) * k2m;             // realigned

    std::printf("npts %d  payload %zu  frame %zu\n", npts, payload, frame);
    std::printf("stride: server %zu, padded %zu\n", stride256, stride2m);
    std::printf("own_stream %s\n\n", own_stream ? "true" : "false");

    Arm arms[] = {
        { "single", 1,      stride256, kOff, nullptr, nullptr },
        { "cycle",  kSlots, stride256, kOff, nullptr, nullptr },
        { "pad2m",  kSlots, stride2m,  kOff, nullptr, nullptr },
        { "cycle0", kSlots, stride256, 0,    nullptr, nullptr },
    };
    const int narms = static_cast<int>(sizeof(arms) / sizeof(arms[0]));

    // Reference signal, and the expected peaks that gate the timing.
    SignalConfig cfg;
    cfg.sample_rate_hz = kRateHz;
    cfg.buffer_size    = npts;
    cfg.freqs_hz       = {5.0e4, 1.2e5};
    cfg.amplitudes     = {1.0f, 0.5f};
    std::vector<float> ref(npts);
    generate_signal(cfg, ref.data(), npts);

    for (int a = 0; a < narms; ++a) {
        size_t bytes = arms[a].stride * static_cast<size_t>(arms[a].slots);
        CUDA_OK(cudaHostAlloc((void**)&arms[a].h_pool, bytes, cudaHostAllocMapped));
        CUDA_OK(cudaHostGetDevicePointer((void**)&arms[a].d_pool, arms[a].h_pool, 0));
        std::printf("%-7s pool %10zu  base %p  payload0 %% 2MB = %5zu  page-aligned %s\n",
                    arms[a].name, bytes, (void*)arms[a].h_pool,
                    ((size_t)arms[a].h_pool + arms[a].offset) % k2m,
                    (((size_t)arms[a].h_pool + arms[a].offset) % 4096 == 0) ? "yes" : "NO");
    }
    std::printf("\n");

    CuFFTExecutor fft(npts, own_stream);
    cufftComplex* d_out = nullptr;
    CUDA_OK(cudaMalloc(&d_out, sizeof(cufftComplex) * (npts / 2 + 1)));

    // Correctness before timing. Every arm must transform to the same spectrum;
    // if an arm is quietly transforming the wrong bytes its time means nothing.
    for (int a = 0; a < narms; ++a) {
        for (int s = 0; s < arms[a].slots; ++s) {
            unsigned char* h = arms[a].h_pool + (size_t)s * arms[a].stride + arms[a].offset;
            std::memcpy(h, ref.data(), payload);
        }
        unsigned char* d = arms[a].d_pool + arms[a].offset;
        fft.execute(reinterpret_cast<const float*>(d), d_out);
        CUDA_OK(cudaDeviceSynchronize());
    }
    std::printf("correctness: all arms transformed without error\n\n");

    // Warmup drives the clocks up and pays plan/JIT costs before any row.
    for (int w = 0; w < warmup; ++w) {
        unsigned char* d = arms[0].d_pool + arms[0].offset;
        fft.execute(reinterpret_cast<const float*>(d), d_out);
    }
    CUDA_OK(cudaDeviceSynchronize());

    std::printf("%-5s %-7s %-10s %-10s\n", "rep", "arm", "fft_p50", "write_p50");
    std::printf("----------------------------------------\n");

    std::vector<std::vector<double>> all(narms);

    for (int r = 0; r < reps; ++r) {
        for (int k = 0; k < narms; ++k) {
            int a = (r + k) % narms;                 // rotate the starting arm
            std::vector<double> fts, wts;
            for (int it = 0; it < iters; ++it) {
                int s = it % arms[a].slots;
                unsigned char* h = arms[a].h_pool + (size_t)s * arms[a].stride + arms[a].offset;
                unsigned char* d = arms[a].d_pool + (size_t)s * arms[a].stride + arms[a].offset;

                cudaEvent_t w0, w1;
                CUDA_OK(cudaEventCreate(&w0)); CUDA_OK(cudaEventCreate(&w1));
                CUDA_OK(cudaEventRecord(w0));
                std::memcpy(h, ref.data(), payload);   // the NIC's write, stood in for
                CUDA_OK(cudaEventRecord(w1));
                CUDA_OK(cudaEventSynchronize(w1));
                float wms = 0.0f;
                CUDA_OK(cudaEventElapsedTime(&wms, w0, w1));
                CUDA_OK(cudaEventDestroy(w0)); CUDA_OK(cudaEventDestroy(w1));

                fft.execute(reinterpret_cast<const float*>(d), d_out);
                fts.push_back(fft.last_exec_us());
                wts.push_back(wms * 1000.0);
            }
            double f = median(fts);
            all[a].push_back(f);
            std::printf("%-5d %-7s %-10.3f %-10.3f\n", r + 1, arms[a].name, f, median(wts));
        }
        std::printf("----------------------------------------\n");
    }

    std::printf("\nmedian of %d reps, us:\n", reps);
    for (int a = 0; a < narms; ++a)
        std::printf("  %-7s %8.3f\n", arms[a].name, median(all[a]));

    double single = median(all[0]), cycle = median(all[1]);
    double pad2m  = median(all[2]), cycle0 = median(all[3]);
    std::printf("\n  working set (cycle - single) : %+7.3f\n", cycle - single);
    std::printf("  stride      (pad2m - cycle)  : %+7.3f\n", pad2m - cycle);
    std::printf("  offset      (cycle0 - cycle) : %+7.3f\n", cycle0 - cycle);

    for (int a = 0; a < narms; ++a) CUDA_OK(cudaFreeHost(arms[a].h_pool));
    CUDA_OK(cudaFree(d_out));
    std::printf("\nDONE_SLOTGEOM\n");
    return 0;
}
