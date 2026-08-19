// bench_fft_memsrc.cc — where does cuFFT's input have to live?
//
// ---------------------------------------------------------------------------
// WHY THIS EXISTS
// ---------------------------------------------------------------------------
// The 54-run headline sweep established that ~80 % of the remaining gRPC/DAQiri
// gap is inside cuFFT itself, that it grows with payload (0.77 us at 16 KB to
// 6.40 us at 4 MB), and that both pipelines run a byte-identical transform:
// same cufftPlan1d R2C, same n, batch 1, default strides, out-of-place, no work
// area, one JIT warmup, plan built once, output to cudaMalloc'd device memory
// in both.  The only thing that differs is WHERE THE TRANSFORM READS FROM.
//
// The intended test was "same plan over a self-allocated buffer vs the loaned
// iceoryx2 buffer, no gRPC."  That turns out to be unreachable: grpc-direct
// exposes no C++ loan API, the iceoryx2 sample lifecycle lives entirely inside
// the Rust library, and the server only ever receives a pointer someone else
// loaned.  Standing up a fake publisher to get one would put the Rust runtime
// back in the measurement, which is the thing we were trying to remove.
//
// So this harness attacks the same question from the other side.  Instead of
// obtaining the pipeline's buffer, it constructs each MEMORY KIND directly and
// times the identical transform over each:
//
//   device     cudaMalloc                          the floor: real device memory
//   hostalloc  cudaHostAlloc(Mapped)               what DAQiri's MR is made of
//   heapreg    aligned heap + cudaHostRegister     anonymous private mapping
//   shmreg     /dev/shm mmap + cudaHostRegister    what iceoryx2 hands us
//   hugereg    THP/hugetlb mmap + cudaHostRegister the page-size hypothesis
//
// That ladder decides the open question.  If shmreg loses to heapreg, the
// problem is that the memory is file-backed shared rather than anonymous, which
// is a property of iceoryx2's arena and lands on the Rust side of the boundary.
// If heapreg and shmreg tie and both lose to hostalloc, the problem is
// cudaHostRegister itself and no arena change would rescue it.  If hugereg
// recovers the difference, it is page-table pressure and the fix is ours to
// make.  Each of those outcomes points at a different next move, which is why
// one number would not have been enough.
//
// ---------------------------------------------------------------------------
// METHOD, AND WHY IT IS SHAPED THIS WAY
// ---------------------------------------------------------------------------
// GPU clocks cannot be locked on GB10, and three of this project's headline
// numbers have already turned out to be measurement artifacts.  So:
//
//   * Arms are interleaved at the finest possible grain: one iteration of every
//     arm, then the next iteration.  Adjacent samples from different arms are
//     microseconds apart, so DVFS drift is common-mode and cancels.  Comparing
//     block-of-A against block-of-B is exactly how the thermal artifact got in.
//   * >= 3 reps by default.  Interleaving removes bias BETWEEN arms; only
//     repeats show how much a single measurement moves.  A correctly
//     interleaved single-rep run once reported 2.91 us for a gap that was 8.10.
//   * Every arm's usable pointer is aligned to 2 MB, so alignment is held
//     constant and cannot be the explanation.  Alignment was the E2 bug; it is
//     not being allowed back in as a free variable.
//   * Results are reported per byte as well as absolute.  A per-byte slope is
//     the signature that separates a placement cost from fixed launch overhead,
//     and it is the claim that will be challenged.
//   * Timing is the CUDA-event GPU time of the transform (last_exec_us), the
//     same quantity the pipeline reports as fft_p50, not wall time around an
//     async call.  Wall time around an enqueue is how the 77 us copy hid.
//   * Correctness runs before timing and every arm must produce the same top-3
//     spectral peaks.  A failed launch leaves the output untouched, which reads
//     as a very fast result.
//   * An arm that cannot be constructed as specified says so loudly instead of
//     silently degrading into a duplicate of another arm.  hugereg in
//     particular will fall back from hugetlb to THP to nothing, and a THP
//     region below 2 MB is just heapreg wearing a hat.
//
// Build:  cmake --build build_grpc --parallel 16 --target bench_fft_memsrc
// Run:    ./bench_fft_memsrc --sizes 4096,65536,262144,524288,1048576 --reps 3

#include <cuda_runtime.h>

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <csetjmp>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <string>
#include <vector>

#include "cufft_executor.h"
#include "signal_gen.h"

#ifndef MADV_HUGEPAGE
#  define MADV_HUGEPAGE 14
#endif
#ifndef MAP_HUGETLB
#  define MAP_HUGETLB 0x40000
#endif

#define CUDA_CHECK(x)                                                        \
    do {                                                                     \
        cudaError_t e_ = (x);                                                \
        if (e_ != cudaSuccess) {                                             \
            std::fprintf(stderr, "CUDA error %s at %s:%d\n",                 \
                         cudaGetErrorString(e_), __FILE__, __LINE__);        \
            std::exit(1);                                                    \
        }                                                                    \
    } while (0)

namespace {

constexpr size_t kAlign = 2u * 1024 * 1024;   // 2 MB, also the THP size

size_t align_up(size_t v, size_t a) { return (v + a - 1) & ~(a - 1); }

// ── what actually backs a mapping ────────────────────────────────────────────
// Walks /proc/self/smaps to the entry containing `p` and reports the fields
// that decide page size.  This exists because a name is not evidence: the
// 'hugereg' arm calls madvise(MADV_HUGEPAGE), but madvise is a request, not a
// guarantee, and the kernel is free to leave the region on 4 KB pages.  An
// earlier sweep reported that arm as "THP" on the strength of madvise
// returning 0, which proves only that the kernel accepted the hint.  If
// AnonHugePages comes back 0 here, the arm was never a huge-page arm and any
// null result from it says nothing about page size.
std::string smaps_backing(const void* p) {
    const uintptr_t want = reinterpret_cast<uintptr_t>(p);
    std::FILE* f = std::fopen("/proc/self/smaps", "r");
    if (!f) return "smaps unavailable";

    char     line[512];
    bool     in_range = false;
    long     kernel_pagesize = 0, anon_huge = -1, file_pmd = -1, rss = 0;
    std::string vmflags, backing;

    while (std::fgets(line, sizeof line, f)) {
        unsigned long lo = 0, hi = 0;
        int           consumed = 0;
        // A header line is: addr-addr perms offset dev inode pathname
        if (std::sscanf(line, "%lx-%lx %*s %*s %*s %*s %n", &lo, &hi, &consumed) == 2) {
            if (in_range) break;                 // we already passed our entry
            in_range = (want >= lo && want < hi);
            if (in_range) {
                backing = (consumed > 0) ? std::string(line + consumed) : std::string();
                while (!backing.empty() &&
                       (backing.back() == '\n' || backing.back() == ' '))
                    backing.pop_back();
                if (backing.empty()) backing = "anonymous";
            }
            continue;
        }
        if (!in_range) continue;
        long v = 0;
        if (std::sscanf(line, "KernelPageSize: %ld kB", &v) == 1) kernel_pagesize = v;
        else if (std::sscanf(line, "AnonHugePages: %ld kB", &v) == 1) anon_huge = v;
        else if (std::sscanf(line, "FilePmdMapped: %ld kB", &v) == 1) file_pmd = v;
        else if (std::sscanf(line, "Rss: %ld kB", &v) == 1)          rss = v;
        else if (std::strncmp(line, "VmFlags:", 8) == 0) {
            vmflags = line + 8;
            while (!vmflags.empty() && (vmflags.back() == '\n' || vmflags.back() == ' '))
                vmflags.pop_back();
        }
    }
    std::fclose(f);
    if (!in_range && backing.empty()) return "no smaps entry (driver-private mapping)";

    char out[512];
    std::snprintf(out, sizeof out,
                  "pagesize=%ldkB rss=%ldkB anonhuge=%ldkB filepmd=%ldkB back=%s%s",
                  kernel_pagesize, rss, anon_huge, file_pmd,
                  backing.c_str(), vmflags.empty() ? "" : (" vmflags:" + vmflags).c_str());
    return out;
}

// One memory kind under test.  `use` is what cuFFT reads; `host` is where we
// write the signal (null for the device arm, which needs a copy instead).
struct Arm {
    std::string name;
    float*      host = nullptr;   // host-visible pointer, null for device arm
    float*      use  = nullptr;   // device pointer handed to cuFFT
    void*       raw  = nullptr;   // base to release
    size_t      raw_bytes = 0;
    bool        registered = false;
    bool        is_mmap    = false;
    bool        is_device  = false;
    bool        is_hostalloc = false;  // release with cudaFreeHost
    int         shm_fd     = -1;
    std::string note;             // how it was actually built, if degraded
    std::vector<float> samples;        // transform time, GPU us
    std::vector<float> write_samples;  // producer write time, CPU us
    bool        direct_write = false;  // CPU stores straight into device memory
    bool        is_managed   = false;  // cudaMallocManaged, freed with cudaFree
    bool        usable       = true;   // false if the arm faulted when probed
};

// ── can the CPU store into this pointer without dying? ──────────────────────
// On a discrete GPU, writing to a cudaMalloc'd pointer from the CPU is a
// segfault.  GB10 is coherent, so it may be legal here, but "may" is not good
// enough to find out by crashing the benchmark halfway through a sweep.  One
// guarded byte-store answers it, and the arm is dropped cleanly if it faults.
sigjmp_buf              g_probe_jmp;
volatile sig_atomic_t   g_probe_faulted = 0;

extern "C" void probe_fault_handler(int) {
    g_probe_faulted = 1;
    siglongjmp(g_probe_jmp, 1);
}

bool host_can_store(void* p) {
    struct sigaction sa {}, old_segv {}, old_bus {};
    sa.sa_handler = probe_fault_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGBUS,  &sa, &old_bus);

    g_probe_faulted = 0;
    bool ok = true;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        *static_cast<volatile char*>(p) = 0;
    } else {
        ok = false;
    }

    sigaction(SIGSEGV, &old_segv, nullptr);
    sigaction(SIGBUS,  &old_bus,  nullptr);
    return ok;
}

// Append to an arm's note without losing what is already there.  Several of
// the Phase 1 arms can pick up two remarks (a fallback and an exclusion), and
// an overwritten note would misreport how the arm was actually built.
void add_note(Arm& a, const std::string& s) {
    if (!a.note.empty()) a.note += "; ";
    a.note += s;
}

// Register a host span and resolve its device pointer.
//
// `flags` is the variable under test in the Phase 1 ladder, so it is a
// parameter rather than the constant it used to be.  Registration can fail for
// a legitimate reason (this driver rejects cudaHostRegisterReadOnly outright),
// and one unsupported flag must not cost the whole sweep, so a failure marks
// the arm unusable instead of aborting.
//
// `reg_bytes` allows registering a span larger than the payload.  That is the
// page-rounded registration --zc-bigreg tested on the server, re-run here under
// write-then-transform discipline, because its original null came from the
// read-only ladder that has since been retracted.
bool register_and_map(Arm& a, size_t bytes, unsigned flags, size_t reg_bytes = 0) {
    if (reg_bytes == 0) reg_bytes = bytes;
    const cudaError_t rc = cudaHostRegister(a.host, reg_bytes, flags);
    if (rc != cudaSuccess) {
        cudaGetLastError();            // clear the sticky error
        a.usable = false;
        a.use    = a.host;
        add_note(a, std::string("EXCLUDED: cudaHostRegister rejected: ")
                    + cudaGetErrorString(rc));
        return true;                   // built, but excluded from measurement
    }
    a.registered = true;

    // Without cudaHostRegisterMapped there is no mapped device pointer to ask
    // for.  That is not fatal here: gate 1 showed cudaHostGetDevicePointer
    // returning the same address cudaHostAlloc did, so unified addressing makes
    // the host pointer device-usable on this part.  Fall back to it and record
    // that we did, because an unrecorded fallback would quietly turn a
    // flag-comparison arm into a different experiment.
    void* dev = nullptr;
    if (cudaHostGetDevicePointer(&dev, a.host, 0) == cudaSuccess && dev) {
        a.use = static_cast<float*>(dev);
    } else {
        cudaGetLastError();
        a.use = a.host;
        add_note(a, "no mapped devptr, using host ptr (unified addressing)");
    }
    return true;
}

// Build a /dev/shm mapping, the same class of object iceoryx2 hands the server
// (its segments show up as /dev/shm/iox2_*).  Split out of the shmreg arm
// because every Phase 1 registration arm needs a byte-identical mapping and
// must differ ONLY in the flag passed to cudaHostRegister.  Sharing the
// construction is what makes that a controlled comparison rather than four
// separate experiments.  Each arm gets its own segment name so arms measured in
// the same run cannot collide over one.
bool map_shm(Arm& a, size_t slack, const std::string& tag) {
    const std::string nm = "/fft_memsrc_" + tag;
    shm_unlink(nm.c_str());
    int fd = shm_open(nm.c_str(), O_CREAT | O_RDWR | O_EXCL, 0600);
    if (fd < 0) return false;
    if (ftruncate(fd, static_cast<off_t>(slack)) != 0) {
        close(fd); shm_unlink(nm.c_str()); return false;
    }
    void* h = mmap(nullptr, slack, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    shm_unlink(nm.c_str());   // unlink now; the mapping keeps it alive
    if (h == MAP_FAILED) { close(fd); return false; }
    a.shm_fd    = fd;
    a.raw       = h;
    a.raw_bytes = slack;
    a.is_mmap   = true;
    a.host = reinterpret_cast<float*>(
        align_up(reinterpret_cast<uintptr_t>(h), kAlign));
    return true;
}

// ── Phase 1: the allocator and registration flag ladder ────────────────────
// 7c established that driver-allocated pinned memory beats
// user-allocated-then-registered memory by 10.94 us of transform time at 4 MB,
// on both halves, which is more than the entire remaining gap to DAQiri.  It
// did not establish WHY, and the leading guess is that allocation-time page
// attributes (cacheability) differ from anything registration can retroactively
// apply.  These arms hold the mapping constant and vary only the flag.
//
// The stake is the scope of the whole project: if some cudaHostRegister flag
// closes the gap, the fix is one line and the RDMA transport becomes optional.
// If none does, the penalty is inherent to registration, owning the allocation
// is the only way out, and the transport work proceeds with a real
// justification instead of an assumed one.
struct FlagArm { const char* name; unsigned flags; const char* what; };

const FlagArm kAllocArms[] = {
    {"ha_def",   cudaHostAllocDefault,
     "cudaHostAlloc Default"},
    {"ha_wc",    cudaHostAllocWriteCombined,
     "cudaHostAlloc WriteCombined (uncached for CPU reads; our producer only writes)"},
    {"ha_wcmap", cudaHostAllocMapped | cudaHostAllocWriteCombined,
     "cudaHostAlloc Mapped|WriteCombined"},
};

const FlagArm kRegisterArms[] = {
    {"shmreg_def",  cudaHostRegisterDefault,  "cudaHostRegister Default"},
    {"shmreg_port", cudaHostRegisterPortable, "cudaHostRegister Portable"},
    {"shmreg_ro",   cudaHostRegisterMapped | cudaHostRegisterReadOnly,
     "cudaHostRegister Mapped|ReadOnly (the transform is out-of-place, so "
     "read-only input is legal here)"},
};

bool build_arm(Arm& a, const std::string& kind, size_t bytes) {
    a.name = kind;
    const size_t slack = bytes + kAlign;

    if (kind == "device") {
        // Device memory reached the only way it normally can be: by copying.
        // Its write cost is a full H2D transfer, which is the thing that makes
        // "just put it on the GPU" lose.  Included precisely so that shows up.
        a.is_device = true;
        void* d = nullptr;
        CUDA_CHECK(cudaMalloc(&d, slack));
        a.raw = d;
        a.raw_bytes = slack;
        a.use = reinterpret_cast<float*>(
            align_up(reinterpret_cast<uintptr_t>(d), kAlign));
        return true;
    }

    if (kind == "devwrite") {
        // The i-RDMA proxy: data LANDS in device memory instead of being
        // copied there.  We stand in for the producer with a CPU store, which
        // is only meaningful if the coherent link allows it at all.
        a.is_device    = true;
        a.direct_write = true;
        void* d = nullptr;
        CUDA_CHECK(cudaMalloc(&d, slack));
        a.raw = d;
        a.raw_bytes = slack;
        a.use = reinterpret_cast<float*>(
            align_up(reinterpret_cast<uintptr_t>(d), kAlign));
        a.host = a.use;   // same address; coherent part, if it works at all
        if (!host_can_store(a.host)) {
            a.usable = false;
            a.note   = "FAULTS: device memory is not CPU-writable on this box";
        } else {
            a.note = "CPU stores directly into device memory";
        }
        return true;
    }

    if (kind == "mgdwrite") {
        // Route C: managed memory pinned to the GPU by advice, then prefetched
        // there.  This is the ONLY CPU-writable way to reach device-resident
        // memory on this box, since plain cudaMalloc faults on a CPU store.
        // The risk is the whole point of measuring it: a CPU write may migrate
        // the pages straight back to the host, which is a copy in disguise and
        // would show up as a large write cost here.
        a.is_device    = true;
        a.direct_write = true;
        void* m = nullptr;
        if (cudaMallocManaged(&m, slack) != cudaSuccess) {
            a.usable = false;
            a.note   = "FAULTS: cudaMallocManaged failed";
            return true;
        }
        a.raw = m;
        a.raw_bytes = slack;
        a.is_managed = true;
        int dev = 0;
        cudaGetDevice(&dev);
        // CUDA 13 replaced the int-device form of these with a cudaMemLocation.
        cudaMemLocation loc {};
        loc.type = cudaMemLocationTypeDevice;
        loc.id   = dev;
        cudaMemAdvise(m, slack, cudaMemAdviseSetPreferredLocation, loc);
        cudaMemPrefetchAsync(m, slack, loc, 0, cudaStream_t(0));
        cudaDeviceSynchronize();
        a.use  = reinterpret_cast<float*>(
            align_up(reinterpret_cast<uintptr_t>(m), kAlign));
        a.host = a.use;
        if (!host_can_store(a.host)) {
            a.usable = false;
            a.note   = "FAULTS: managed memory not CPU-writable";
        } else {
            a.note = "managed, preferred location = GPU";
        }
        return true;
    }

    if (kind == "hostalloc") {
        void* h = nullptr;
        CUDA_CHECK(cudaHostAlloc(&h, slack, cudaHostAllocMapped));
        a.raw = h;
        a.raw_bytes = slack;
        a.is_hostalloc = true;
        a.host = reinterpret_cast<float*>(
            align_up(reinterpret_cast<uintptr_t>(h), kAlign));
        void* dev = nullptr;
        CUDA_CHECK(cudaHostGetDevicePointer(&dev, a.host, 0));
        a.use = static_cast<float*>(dev);   // already mapped by cudaHostAlloc
        return true;
    }

    // Allocation-side flag arms.  Identical to `hostalloc` except for the flag,
    // which is the point: `hostalloc` is the Mapped case and stays under its
    // original name so the 15-rep result in 7c remains directly comparable.
    for (const FlagArm& f : kAllocArms) {
        if (kind != f.name) continue;
        void* h = nullptr;
        const cudaError_t rc = cudaHostAlloc(&h, slack, f.flags);
        if (rc != cudaSuccess) {
            cudaGetLastError();
            a.usable = false;
            add_note(a, std::string("EXCLUDED: cudaHostAlloc rejected: ")
                        + cudaGetErrorString(rc));
            return true;
        }
        a.raw = h;
        a.raw_bytes = slack;
        a.is_hostalloc = true;
        a.host = reinterpret_cast<float*>(
            align_up(reinterpret_cast<uintptr_t>(h), kAlign));
        add_note(a, f.what);
        void* dev = nullptr;
        if (cudaHostGetDevicePointer(&dev, a.host, 0) == cudaSuccess && dev) {
            a.use = static_cast<float*>(dev);
        } else {
            cudaGetLastError();
            a.use = a.host;
            add_note(a, "no mapped devptr, using host ptr (unified addressing)");
        }
        return true;
    }

    if (kind == "heapreg") {
        void* h = std::malloc(slack);
        if (!h) return false;
        a.raw = h;
        a.raw_bytes = slack;
        a.host = reinterpret_cast<float*>(
            align_up(reinterpret_cast<uintptr_t>(h), kAlign));
        return register_and_map(a, bytes, cudaHostRegisterMapped);
    }

    if (kind == "shmreg") {
        // A file-backed shared mapping under /dev/shm, which is the same kind
        // of object iceoryx2 hands the server (its segments show up as
        // /dev/shm/iox2_*).  This is the arm that stands in for the loaned
        // buffer we cannot obtain directly.
        if (!map_shm(a, slack, kind)) return false;
        return register_and_map(a, bytes, cudaHostRegisterMapped);
    }

    // Registration-side flag arms, on a byte-identical /dev/shm mapping.
    for (const FlagArm& f : kRegisterArms) {
        if (kind != f.name) continue;
        if (!map_shm(a, slack, kind)) return false;
        add_note(a, f.what);
        return register_and_map(a, bytes, f.flags);
    }

    if (kind == "shmreg_big") {
        // Page-rounded registration: register a 2 MB-aligned span instead of the
        // exact payload.  This is --zc-bigreg's hypothesis (that registration
        // granularity, not memory kind, is what costs us) re-tested under
        // write-then-transform discipline.  Its original null result predates
        // the discovery that a read-only ladder cannot answer this question.
        const size_t reg_bytes = align_up(bytes, kAlign);
        if (!map_shm(a, reg_bytes + kAlign, kind)) return false;
        add_note(a, "registration span rounded up to " +
                    std::to_string(reg_bytes / (1024 * 1024)) + " MB");
        return register_and_map(a, bytes, cudaHostRegisterMapped, reg_bytes);
    }

    if (kind == "hugereg") {
        // Try real hugetlb first.  It needs preallocated pages
        // (/proc/sys/vm/nr_hugepages) and will usually fail, so fall back to
        // transparent huge pages.  Whichever we get is recorded in `note`,
        // because a silent fallback would make this arm a duplicate of heapreg.
        void* h = mmap(nullptr, slack, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
        if (h != MAP_FAILED) {
            a.note = "hugetlb";
        } else {
            h = mmap(nullptr, slack, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (h == MAP_FAILED) return false;
            if (madvise(h, slack, MADV_HUGEPAGE) == 0) {
                a.note = (bytes >= kAlign) ? "THP" : "THP(payload<2MB, no effect)";
            } else {
                a.note = "DEGRADED: madvise refused, 4 KB pages";
            }
        }
        a.raw = h;
        a.raw_bytes = slack;
        a.is_mmap = true;
        a.host = reinterpret_cast<float*>(
            align_up(reinterpret_cast<uintptr_t>(h), kAlign));
        // Fault the pages in before registering so THP can actually collapse
        // them; registering a region of untouched pages would measure the
        // fault path instead of the transform.
        std::memset(a.host, 0, bytes);
        return register_and_map(a, bytes, cudaHostRegisterMapped);
    }

    return false;
}

void destroy_arm(Arm& a) {
    if (a.registered && a.host) cudaHostUnregister(a.host);
    if (a.is_device && a.raw)     cudaFree(a.raw);
    else if (a.is_mmap && a.raw)  munmap(a.raw, a.raw_bytes);
    else if (a.is_hostalloc && a.raw) cudaFreeHost(a.raw);
    else if (a.raw) std::free(a.raw);
    if (a.shm_fd >= 0) close(a.shm_fd);
    a.raw = nullptr; a.host = nullptr; a.use = nullptr; a.registered = false;
}

float pct(std::vector<float> v, double p) {
    if (v.empty()) return 0.0f;
    std::sort(v.begin(), v.end());
    size_t i = static_cast<size_t>(p * (v.size() - 1) + 0.5);
    return v[i];
}

// Median across reps.  Reps are summarised by median rather than mean so one
// thermally unlucky rep cannot drag the verdict.
float med_of(std::vector<float> v) { return pct(std::move(v), 0.50); }

std::vector<size_t> parse_sizes(const std::string& s) {
    std::vector<size_t> out;
    size_t pos = 0;
    while (pos <= s.size()) {
        size_t c = s.find(',', pos);
        if (c == std::string::npos) c = s.size();
        if (c > pos) out.push_back(std::strtoull(s.substr(pos, c - pos).c_str(), nullptr, 10));
        pos = c + 1;
    }
    return out;
}

}  // namespace

int main(int argc, char** argv) {
    std::string sizes_s = "4096,65536,262144,524288,1048576";
    std::string arms_s  = "devwrite,mgdwrite,device,hostalloc,heapreg,shmreg,hugereg";
    int    reps = 3, iters = 200, warmup = 50;
    double pace_us = 0.0;
    std::string out_csv = "data/memsrc_runs.csv";
    std::string gitsha  = "unknown";

    for (int i = 1; i < argc; ++i) {
        std::string f = argv[i];
        auto next = [&]() { return (i + 1 < argc) ? argv[++i] : ""; };
        if      (f == "--sizes")  sizes_s = next();
        else if (f == "--arms")   arms_s  = next();
        else if (f == "--reps")   reps    = std::atoi(next());
        else if (f == "--iters")  iters   = std::atoi(next());
        else if (f == "--warmup") warmup  = std::atoi(next());
        else if (f == "--pace-us")pace_us = std::atof(next());
        else if (f == "--out")    out_csv = next();
        else if (f == "--gitsha") gitsha  = next();
        else if (f == "--help") {
            std::printf("usage: %s [--sizes a,b,c] [--arms ...] [--reps N] "
                        "[--iters N] [--warmup N] [--out f.csv] [--gitsha s]\n", argv[0]);
            return 0;
        }
    }

    const std::vector<size_t> sizes = parse_sizes(sizes_s);
    std::vector<std::string>  arm_names;
    { size_t pos = 0;
      while (pos <= arms_s.size()) {
          size_t c = arms_s.find(',', pos);
          if (c == std::string::npos) c = arms_s.size();
          if (c > pos) arm_names.push_back(arms_s.substr(pos, c - pos));
          pos = c + 1;
      } }

    std::printf("cuFFT input-placement ladder: WRITE + TRANSFORM\n");
    std::printf("build: %s   %d reps x %zu arms x %zu sizes, "
                "arms interleaved per iteration\n\n",
                gitsha.c_str(), reps, arm_names.size(), sizes.size());
    std::printf(
        "Why both halves are reported:\n"
        "  In the pipeline benchmark the producer's write happens OUTSIDE the\n"
        "  measured window.  A change that makes the write slower and the\n"
        "  transform faster would therefore look like a pure win while being\n"
        "  neutral or worse in reality.  Reporting the transform alone would be\n"
        "  a stopwatch artifact, so write, transform and their total are all\n"
        "  below and the verdict is taken on the TOTAL.\n\n"
        "Decision rule, fixed before the data exists:\n"
        "  Reading from device memory was worth 6.10 us at 4 MB in the earlier\n"
        "  read-only ladder (47.55 vs 53.66).  So if landing data in device\n"
        "  memory costs MORE than 6.10 us of extra write time, the direction is\n"
        "  dead and no implementation route gets started.\n\n"
        "Note on the 'device' arm: it reaches device memory the only way it\n"
        "  normally can, by copying.  Its write column is a full H2D transfer.\n"
        "  'devwrite' is the one that matters: the data LANDS there.\n\n");

    FILE* csv = std::fopen(out_csv.c_str(), "w");
    if (!csv) { std::fprintf(stderr, "cannot open %s\n", out_csv.c_str()); return 1; }
    std::fprintf(csv, "arm,size,kb,rep,write_p50,fft_p50,total_p50,fft_p90,"
                      "us_per_mb,n,note,gitsha\n");

    for (size_t nsamp : sizes) {
        const size_t bytes = nsamp * sizeof(float);
        const double mb    = double(bytes) / (1024.0 * 1024.0);
        const int    kb    = int(bytes / 1024);

        std::vector<Arm> arms(arm_names.size());
        bool ok = true;
        for (size_t i = 0; i < arm_names.size(); ++i) {
            if (!build_arm(arms[i], arm_names[i], bytes)) {
                std::fprintf(stderr, "ABORT: could not build arm '%s' at %zu samples\n",
                             arm_names[i].c_str(), nsamp);
                ok = false;
                break;
            }
        }
        if (!ok) { for (auto& a : arms) destroy_arm(a); break; }

        // Same three-tone signal in every arm, so any peak mismatch below is a
        // real failure and not a difference in the input.
        SignalConfig cfg;
        cfg.sample_rate_hz = 1'000'000.0f;
        cfg.buffer_size    = int(nsamp);
        cfg.freqs_hz       = {500.0f, 1200.0f, 2500.0f};
        cfg.amplitudes     = {1.2f, 0.6f, 0.3f};
        std::vector<float> sig(nsamp);
        generate_signal(cfg, sig.data(), int(nsamp));

        for (auto& a : arms) {
            if (!a.usable) continue;
            if (a.is_device && !a.direct_write)
                CUDA_CHECK(cudaMemcpy(a.use, sig.data(), bytes, cudaMemcpyHostToDevice));
            else
                std::memcpy(a.host, sig.data(), bytes);
        }

        // Braces, not parens: `exec(int(nsamp))` is a function declaration.
        CuFFTExecutor exec{int(nsamp)};
        cufftComplex* d_out = nullptr;
        CUDA_CHECK(cudaMalloc(&d_out, sizeof(cufftComplex) * (nsamp / 2 + 1)));

        // ── alignment audit: prove it is not the variable ──────────────────
        std::printf("== %d KB ==\n", kb);
        for (auto& a : arms) {
            std::printf("   %-10s ptr %% 2MB = %-8zu %s\n", a.name.c_str(),
                        size_t(reinterpret_cast<uintptr_t>(a.use) % kAlign),
                        a.note.empty() ? "" : a.note.c_str());
            if (a.note.rfind("DEGRADED", 0) == 0)
                std::printf("   WARNING: arm '%s' is degraded: %s\n",
                            a.name.c_str(), a.note.c_str());
            if (!a.usable)
                std::printf("   EXCLUDED: arm '%s' cannot be measured here\n",
                            a.name.c_str());
            if (a.usable)
                std::printf("   %-10s SMAPS %s\n", a.name.c_str(),
                            smaps_backing(a.host ? static_cast<void*>(a.host)
                                                 : static_cast<void*>(a.use)).c_str());
            // A huge-page arm that reports anonhuge=0 is a 4 KB arm wearing the
            // wrong label, and its result must not be read as a page-size test.
            if (a.name == "hugereg" &&
                smaps_backing(a.host).find("anonhuge=0kB") != std::string::npos)
                std::printf("   WARNING: 'hugereg' got NO huge pages; this arm does "
                            "not test page size\n");
        }

        // ── usability probe, before correctness ───────────────────────────
        // A registration arm built without cudaHostRegisterMapped falls back to
        // the host pointer, and cuFFT may refuse it.  Probe once with the
        // non-throwing form so one unsupported flag drops its own arm instead
        // of aborting a sweep that the other arms would have answered.
        for (auto& a : arms) {
            if (!a.usable) continue;
            if (!exec.try_execute(a.use, d_out)) {
                a.usable = false;
                add_note(a, "EXCLUDED: cuFFT rejected this pointer");
                std::printf("   EXCLUDED: arm '%s' -> cuFFT rejected its pointer\n",
                            a.name.c_str());
            }
        }

        // ── correctness before timing ──────────────────────────────────────
        for (auto& a : arms) if (a.usable) exec.execute(a.use, d_out);
        bool peaks_ok = true;
        std::string ref;
        for (auto& a : arms) {
            if (!a.usable) continue;
            exec.execute(a.use, d_out);
            auto pk = exec.detect_peaks(d_out, 3, cfg.sample_rate_hz);
            char line[256]; line[0] = '\0';
            for (auto& p : pk) {
                char t[64];
                std::snprintf(t, sizeof t, "%.1f Hz ", p.first);
                std::strncat(line, t, sizeof(line) - std::strlen(line) - 1);
            }
            std::printf("   %-10s peaks: %s\n", a.name.c_str(), line);
            if (ref.empty()) ref = line;
            else if (ref != line) peaks_ok = false;
        }
        if (!peaks_ok) {
            std::printf("   ABORT: arms disagree on the spectrum; timing below would be meaningless\n");
            cudaFree(d_out);
            for (auto& a : arms) destroy_arm(a);
            std::fclose(csv);
            return 1;
        }

        // Per-size accumulators so a verdict can be taken after all reps.
        std::vector<std::vector<float>> tot_by_arm(arms.size());

        for (int rep = 1; rep <= reps; ++rep) {
            for (auto& a : arms) { a.samples.clear(); a.write_samples.clear(); }

            for (int it = 0; it < warmup + iters; ++it) {
                // Interleave at the finest grain, and ROTATE the starting arm
                // each iteration.  Interleaving alone is not enough: with a
                // fixed order the arm listed first always runs straight after
                // the pace gap, and every later arm re-reads a source buffer
                // the earlier arms just pulled into cache.  That makes
                // position a hidden variable perfectly correlated with arm
                // identity.  An earlier fixed-order run had the first-listed
                // arm win 15/15 against all three others, which is exactly
                // what an order effect looks like.  Rotating spreads every arm
                // evenly across every slot, so position averages out.
                for (size_t k = 0; k < arms.size(); ++k) {
                    Arm& a = arms[(size_t(it) + k) % arms.size()];
                    if (!a.usable) continue;

                    // Producer write, then transform, in pipeline order.  The
                    // write is plain wall-clock CPU work, so steady_clock is
                    // the right instrument; the transform is GPU work, so it
                    // keeps using the CUDA-event time.  Mixing those up is how
                    // the first retracted number on this project happened.
                    const auto w0 = std::chrono::steady_clock::now();
                    if (a.is_device && !a.direct_write) {
                        CUDA_CHECK(cudaMemcpy(a.use, sig.data(), bytes,
                                              cudaMemcpyHostToDevice));
                    } else {
                        std::memcpy(a.host, sig.data(), bytes);
                    }
                    const auto w1 = std::chrono::steady_clock::now();

                    exec.execute(a.use, d_out);

                    if (it >= warmup) {
                        a.write_samples.push_back(float(
                            std::chrono::duration<double>(w1 - w0).count() * 1e6));
                        a.samples.push_back(exec.last_exec_us());
                    }
                }
                if (pace_us > 0) {
                    struct timespec ts{0, long(pace_us * 1000.0)};
                    nanosleep(&ts, nullptr);
                }
            }

            for (size_t i = 0; i < arms.size(); ++i) {
                Arm& a = arms[i];
                if (!a.usable) continue;
                float wp50  = pct(a.write_samples, 0.50);
                float p50   = pct(a.samples, 0.50);
                float p90   = pct(a.samples, 0.90);
                float total = wp50 + p50;
                tot_by_arm[i].push_back(total);
                std::printf("   rep %d  %-10s write %8.3f   fft %8.3f   "
                            "total %8.3f us   %8.3f us/MB\n",
                            rep, a.name.c_str(), wp50, p50, total, total / mb);
                std::fprintf(csv, "%s,%zu,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%zu,%s,%s\n",
                             a.name.c_str(), nsamp, kb, rep, wp50, p50, total, p90,
                             total / mb, a.samples.size(),
                             a.note.empty() ? "-" : a.note.c_str(), gitsha.c_str());
            }
            std::fflush(csv);
        }

        // ── verdict for this size ─────────────────────────────────────────
        // shmreg is what our pipeline actually gets today, so it is the thing
        // devwrite has to beat.  Comparing against the best arm overall would
        // flatter the result; comparing against the incumbent is the honest
        // test of "should we change what we do".
        {
            auto idx_of = [&](const char* nm) -> long {
                for (size_t i = 0; i < arms.size(); ++i)
                    if (arms[i].name == nm) return long(i);
                return -1;
            };
            const long i_dw = idx_of("devwrite");
            const long i_sh = idx_of("shmreg");
            if (i_dw >= 0 && i_sh >= 0 && arms[i_dw].usable &&
                !tot_by_arm[i_dw].empty() && !tot_by_arm[i_sh].empty()) {
                const float dw = med_of(tot_by_arm[i_dw]);
                const float sh = med_of(tot_by_arm[i_sh]);
                const float delta = dw - sh;
                std::printf("   VERDICT %d KB: devwrite total %.2f vs shmreg total "
                            "%.2f  ->  %+.2f us  (%s)\n",
                            kb, dw, sh, delta,
                            delta < 0.0f ? "device-landing WINS"
                                         : "device-landing LOSES");
            } else if (i_dw >= 0 && !arms[i_dw].usable) {
                std::printf("   VERDICT %d KB: devwrite unavailable, "
                            "direction cannot be tested this way\n", kb);
            }
        }
        std::printf("\n");

        cudaFree(d_out);
        for (auto& a : arms) destroy_arm(a);
    }

    std::fclose(csv);
    std::printf("DONE_MEMSRC -> %s\n", out_csv.c_str());
    return 0;
}
