// gate4_regmr.cu — the decisive gate for the RoCE-into-cudaHostAlloc design.
//
// THE QUESTION
// The design has the NIC RDMA-write directly into a cudaHostAlloc'd buffer that
// cuFFT then reads in place.  That requires one thing to be true which no
// amount of reading documentation can settle: ibv_reg_mr must ACCEPT
// CUDA-pinned host memory, and the resulting region must be the same bytes the
// GPU sees.  If ibv_reg_mr rejects it, the design is dead and we have lost an
// afternoon instead of a month.
//
// WHAT IS PROVEN HERE
//   1. ibv_reg_mr succeeds on a cudaHostAlloc'd buffer, and its lkey/rkey are
//      printed so the NIC's view is concrete rather than assumed.
//   2. The MR's address and length match the CUDA allocation, so the NIC and
//      the GPU are addressing the same region and not two aliases.
//   3. A GPU kernel writes into that same region and the CPU reads the result,
//      which is the direction that matters: whatever the NIC deposits, the GPU
//      must be able to read, and vice versa.
//   4. CONTROL: the same registration is attempted on cudaMalloc'd DEVICE
//      memory.  Gate 1 reported GPU_DIRECT_RDMA_SUPPORTED = 0 on this chip, so
//      this is expected to FAIL.  Including it turns "we chose host memory"
//      from a preference into a demonstrated constraint.
//
// Build on the Spark:
//   nvcc -O2 -arch=native -o gate4_regmr gate4_regmr.cu -libverbs -lcuda

#include <cuda.h>
#include <cuda_runtime.h>
#include <infiniband/verbs.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdint>

static int g_fail = 0;

#define RT(call)                                                              \
    do {                                                                      \
        cudaError_t e_ = (call);                                              \
        if (e_ != cudaSuccess) {                                              \
            std::printf("  FAIL %s -> %s\n", #call, cudaGetErrorString(e_));  \
            g_fail = 1;                                                       \
        }                                                                     \
    } while (0)

__global__ void stamp(float* p, size_t n, float v) {
    size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) p[i] = v + float(i % 17);
}

int main(int argc, char** argv) {
    const char*  want  = (argc > 1) ? argv[1] : nullptr;   // optional HCA name
    const size_t bytes = 4u << 20;                          // 4 MB, our payload
    const size_t n     = bytes / sizeof(float);

    std::printf("=== Gate 4: will the NIC register CUDA-pinned host memory? ===\n\n");

    // ── pick an HCA ───────────────────────────────────────────────────────
    int                 ndev = 0;
    struct ibv_device** list = ibv_get_device_list(&ndev);
    if (!list || ndev == 0) {
        std::printf("no RDMA devices found (ibv_get_device_list)\n");
        return 2;
    }
    struct ibv_device* pick = list[0];
    if (want) {
        for (int i = 0; i < ndev; ++i)
            if (std::strcmp(ibv_get_device_name(list[i]), want) == 0) pick = list[i];
    }
    std::printf("HCA               : %s   (of %d available)\n",
                ibv_get_device_name(pick), ndev);

    struct ibv_context* ctx = ibv_open_device(pick);
    if (!ctx) { std::printf("ibv_open_device failed: %s\n", std::strerror(errno)); return 2; }
    struct ibv_pd* pd = ibv_alloc_pd(ctx);
    if (!pd) { std::printf("ibv_alloc_pd failed: %s\n", std::strerror(errno)); return 2; }

    // ── the buffer the transport would hand the NIC ────────────────────────
    void* h = nullptr;
    RT(cudaHostAlloc(&h, bytes, cudaHostAllocMapped));
    if (!h) return 2;

    void* d = nullptr;
    RT(cudaHostGetDevicePointer(&d, h, 0));

    std::printf("cudaHostAlloc     : %p  (%zu bytes, cudaHostAllocMapped)\n", h, bytes);
    std::printf("device pointer    : %p\n", d);
    std::printf("same address      : %s\n\n",
                (h == d) ? "YES" : "NO (must translate before handing to cuFFT)");

    // ── THE TEST ──────────────────────────────────────────────────────────
    const int acc = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
                    IBV_ACCESS_REMOTE_READ;
    errno = 0;
    struct ibv_mr* mr = ibv_reg_mr(pd, h, bytes, acc);
    if (!mr) {
        std::printf("*** ibv_reg_mr REJECTED CUDA-pinned host memory: %s\n",
                    std::strerror(errno));
        std::printf("*** GATE 4 FAILS. The design stops here.\n");
        return 1;
    }

    std::printf("ibv_reg_mr        : SUCCESS\n");
    std::printf("  lkey            : 0x%08x\n", mr->lkey);
    std::printf("  rkey            : 0x%08x\n", mr->rkey);
    std::printf("  mr->addr        : %p\n", mr->addr);
    std::printf("  mr->length      : %zu\n", mr->length);
    std::printf("  addr matches    : %s\n",
                (mr->addr == h) ? "YES" : "NO");
    std::printf("  length matches  : %s\n\n",
                (mr->length == bytes) ? "YES" : "NO");

    // ── same bytes from both sides? ───────────────────────────────────────
    // The NIC is not here to write for us, so the GPU stands in for it: if the
    // GPU can write the region and the CPU can read the result, then the region
    // is genuinely shared and not a private alias.
    float* fh = static_cast<float*>(h);
    for (size_t i = 0; i < n; ++i) fh[i] = -1.0f;

    stamp<<<int((n + 255) / 256), 256>>>(static_cast<float*>(d), n, 1000.0f);
    RT(cudaDeviceSynchronize());

    bool coherent = true;
    for (size_t i = 0; i < n; i += 4096)
        if (fh[i] != 1000.0f + float(i % 17)) { coherent = false; break; }

    std::printf("GPU wrote, CPU read back the same region: %s\n",
                coherent ? "YES, coherent" : "NO, values did not match");
    if (!coherent) g_fail = 1;

    // ── CONTROL: device memory should be refused on this chip ─────────────
    std::printf("\n-- control: same call on cudaMalloc'd DEVICE memory --\n");
    void* dev = nullptr;
    if (cudaMalloc(&dev, bytes) == cudaSuccess) {
        errno = 0;
        struct ibv_mr* dmr = ibv_reg_mr(pd, dev, bytes, acc);
        if (dmr) {
            std::printf("  registered (lkey 0x%08x) -- unexpected, GPUDirect RDMA "
                        "may be usable after all\n", dmr->lkey);
            ibv_dereg_mr(dmr);
        } else {
            std::printf("  REJECTED: %s\n", std::strerror(errno));
            std::printf("  This is the expected result: Gate 1 reported\n"
                        "  GPU_DIRECT_RDMA_SUPPORTED = 0, so host memory is not a\n"
                        "  preference here, it is the only option.\n");
        }
        cudaFree(dev);
    }

    ibv_dereg_mr(mr);
    RT(cudaFreeHost(h));
    ibv_dealloc_pd(pd);
    ibv_close_device(ctx);
    ibv_free_device_list(list);

    std::printf("\n=== Gate 4 %s ===\n",
                g_fail ? "COMPLETED WITH ERRORS" : "PASSES");
    return g_fail;
}
