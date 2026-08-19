// gate1_caps.cu — platform capability evidence for the RoCE-into-cudaHostAlloc design.
//
// WHY THIS EXISTS
// The proposed transport has the NIC RDMA-write into a cudaHostAlloc'd host
// buffer, then hands cuFFT a device pointer for the same bytes.  That design
// rests on claims in NVIDIA's documentation.  This program checks those claims
// against this actual chip, because "true in the doc, false on the hardware" is
// the failure mode worth an afternoon to rule out.  The output is committed as
// the evidence that justifies the design.
//
// The one question with a real design consequence:
//   CAN_USE_HOST_POINTER_FOR_REGISTERED_MEM decides whether the host pointer
//   IS the device pointer, or whether every buffer must go through
//   cudaHostGetDevicePointer.  Both are workable; we need to know which.
//
// Build:  nvcc -O2 -arch=native -o gate1_caps gate1_caps.cu -lcuda

#include <cuda.h>
#include <cuda_runtime.h>

#include <cstdio>
#include <cstring>

static int g_fail = 0;

#define RT(call)                                                              \
    do {                                                                      \
        cudaError_t e_ = (call);                                              \
        if (e_ != cudaSuccess) {                                              \
            std::printf("  FAIL %s -> %s\n", #call, cudaGetErrorString(e_));  \
            g_fail = 1;                                                       \
        }                                                                     \
    } while (0)

static const char* drv_err(CUresult r) {
    const char* s = nullptr;
    cuGetErrorName(r, &s);
    return s ? s : "?";
}

// Print one driver attribute.  Attributes can legitimately be absent on a given
// driver version, and that is different from being present and zero, so the two
// cases are reported differently rather than both collapsing to "0".
static void attr(CUdevice dev, CUdevice_attribute a, const char* name,
                 const char* meaning) {
    int      v = -1;
    CUresult r = cuDeviceGetAttribute(&v, a, dev);
    if (r != CUDA_SUCCESS) {
        std::printf("  %-46s UNAVAILABLE (%s)\n", name, drv_err(r));
        return;
    }
    std::printf("  %-46s %d   %s\n", name, v, meaning ? meaning : "");
}

int main() {
    std::printf("=== Gate 1: platform capabilities ===\n\n");

    CUresult r = cuInit(0);
    if (r != CUDA_SUCCESS) {
        std::printf("cuInit failed: %s\n", drv_err(r));
        return 2;
    }

    int rt_ver = 0, drv_ver = 0;
    cudaRuntimeGetVersion(&rt_ver);
    cudaDriverGetVersion(&drv_ver);

    CUdevice dev;
    cuDeviceGet(&dev, 0);
    char name[256] = {0};
    cuDeviceGetName(name, sizeof name, dev);

    cudaDeviceProp p{};
    RT(cudaGetDeviceProperties(&p, 0));

    std::printf("device            : %s  (sm_%d%d)\n", name, p.major, p.minor);
    std::printf("runtime / driver  : %d / %d\n", rt_ver, drv_ver);
    std::printf("integrated        : %d   (1 = shares memory with the host)\n", p.integrated);
    std::printf("canMapHostMemory  : %d\n", p.canMapHostMemory);
    std::printf("unifiedAddressing : %d\n\n", p.unifiedAddressing);

    std::printf("-- the four attributes this design depends on --\n");
    attr(dev, CU_DEVICE_ATTRIBUTE_CAN_USE_HOST_POINTER_FOR_REGISTERED_MEM,
         "CAN_USE_HOST_POINTER_FOR_REGISTERED_MEM",
         "1 = host ptr IS the device ptr");
    attr(dev, CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_SUPPORTED,
         "GPU_DIRECT_RDMA_SUPPORTED",
         "third-party DMA into DEVICE memory");
    // NOTE: these are enumerators, not macros, so #ifdef on them is always
    // false and silently skips the query.  Call them directly and let `attr`
    // report UNAVAILABLE if the driver does not know them.
    attr(dev, CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED,
         "DMA_BUF_SUPPORTED", "dma-buf export of DEVICE memory (deprecated)");
    attr(dev, CU_DEVICE_ATTRIBUTE_HOST_ALLOC_DMA_BUF_SUPPORTED,
         "HOST_ALLOC_DMA_BUF_SUPPORTED",
         "dma-buf export of PAGE-LOCKED HOST memory <- our case");
    attr(dev, CU_DEVICE_ATTRIBUTE_UNIFIED_ADDRESSING,
         "UNIFIED_ADDRESSING", "one virtual address space");

    std::printf("\n-- context: coherence and access model --\n");
    attr(dev, CU_DEVICE_ATTRIBUTE_INTEGRATED, "INTEGRATED", "");
    attr(dev, CU_DEVICE_ATTRIBUTE_CAN_MAP_HOST_MEMORY, "CAN_MAP_HOST_MEMORY", "");
    attr(dev, CU_DEVICE_ATTRIBUTE_PAGEABLE_MEMORY_ACCESS,
         "PAGEABLE_MEMORY_ACCESS", "GPU can read plain malloc");
    attr(dev, CU_DEVICE_ATTRIBUTE_CONCURRENT_MANAGED_ACCESS,
         "CONCURRENT_MANAGED_ACCESS", "");
    attr(dev, CU_DEVICE_ATTRIBUTE_HOST_NATIVE_ATOMIC_SUPPORTED,
         "HOST_NATIVE_ATOMIC_SUPPORTED", "");

    std::printf("\n-- context: RDMA write ordering and flush --\n");
    attr(dev, CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_FLUSH_WRITES_OPTIONS,
         "GPU_DIRECT_RDMA_FLUSH_WRITES_OPTIONS", "bitmask");
    attr(dev, CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_WRITES_ORDERING,
         "GPU_DIRECT_RDMA_WRITES_ORDERING", "0=none 100=owner 200=all");

    // ── the practical question, answered by doing it ──────────────────────
    // The attribute above states the rule; this shows what actually happens to
    // a real buffer of the exact kind the transport will hand the NIC.
    std::printf("\n-- what a real cudaHostAlloc buffer actually looks like --\n");
    const size_t bytes = 4u << 20;
    void*  h   = nullptr;
    void*  d   = nullptr;
    RT(cudaHostAlloc(&h, bytes, cudaHostAllocMapped));
    if (h) {
        RT(cudaHostGetDevicePointer(&d, h, 0));
        std::printf("  host   ptr : %p\n", h);
        std::printf("  device ptr : %p\n", d);
        std::printf("  identical  : %s\n",
                    (h == d) ? "YES  (host ptr is directly usable by the GPU)"
                             : "NO   (must call cudaHostGetDevicePointer)");
        std::printf("  4 KB aligned: %s   2 MB aligned: %s\n",
                    (reinterpret_cast<uintptr_t>(h) % 4096) ? "no" : "yes",
                    (reinterpret_cast<uintptr_t>(h) % (2u << 20)) ? "no" : "yes");

        cudaPointerAttributes pa{};
        if (cudaPointerGetAttributes(&pa, h) == cudaSuccess) {
            const char* t = "?";
            switch (pa.type) {
                case cudaMemoryTypeUnregistered: t = "unregistered"; break;
                case cudaMemoryTypeHost:         t = "host";         break;
                case cudaMemoryTypeDevice:       t = "device";       break;
                case cudaMemoryTypeManaged:      t = "managed";      break;
            }
            std::printf("  pointer type from the driver's view: %s (device %d)\n",
                        t, pa.device);
        }
        RT(cudaFreeHost(h));
    }

    std::printf("\n=== Gate 1 %s ===\n", g_fail ? "had CUDA errors, see FAIL lines"
                                                : "completed");
    return g_fail;
}
