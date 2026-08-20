// gate5_extbuf.cu — does easyrdma accept a cudaHostAlloc'd pool as its landing zone?
//
// This is the gate the whole of Phase 3 rests on. The plan is: stop letting
// easyrdma allocate the receive buffer (which is the cudaHostRegister-shaped
// arrangement Phase 1 measured at +48.7 us of total time at 4 MB) and hand it
// ours instead, via easyrdma_ConfigureExternalBuffer. Gate 4 already proved raw
// ibv_reg_mr accepts a cudaHostAlloc'd pointer. easyrdma is not raw verbs, so
// that is suggestive and not sufficient.
//
// Four questions, and the second is the one that makes the answer trustworthy:
//
//   A. Does ConfigureExternalBuffer accept our pointer, and do the bytes land
//      inside our pool, at the offset we chose, with the rest untouched?
//   B. CONTROL. With plain ConfigureBuffers, is region.buffer *outside* our
//      pool? Without this, A cannot distinguish "external buffers work" from
//      "we misread which pointer we were looking at". A gate that can only
//      pass is not a gate.
//   C. Can the GPU read what landed, through the device pointer, without a copy?
//      Landing in memory cuFFT cannot reach would be a pyrrhic victory.
//   D. PREDICTED FAILURE. Reading easyrdma's source (RdmaConnectedSessionBase.
//      cpp:153) says ConfigureExternalBuffer throws OperationNotSupported when
//      RX polling is enabled. If that prediction is right, external buffers and
//      polling are mutually exclusive and Phase 4 has a confound to handle. If
//      it is wrong, our reading of the library is wrong and everything else here
//      is suspect. Either way it is worth one call to find out.
//
// Runs entirely on the Spark using an RDMA loopback connection over the RoCE
// address, so it does not need the PXI. Cross-machine confirmation comes after.
//
// Build on the Spark:
//   export PATH=/usr/local/cuda-13/bin:$PATH
//   nvcc -O2 -arch=native -std=c++17 -o gate5_extbuf gate5_extbuf.cu \
//        -I$HOME/easyrdma/core/api -L$HOME/easyrdma/core/build \
//        -leasyrdma -lcuda -Xcompiler -pthread
//   LD_LIBRARY_PATH=$HOME/easyrdma/core/build ./gate5_extbuf
//
// Exit code is 0 only if every check passes, so it is usable from a script.

#include <easyrdma.h>

#include <cuda_runtime.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// ---------------------------------------------------------------- plumbing

static int g_failures = 0;
static int g_checks = 0;

static void check(bool ok, const char* what, const char* detail = "")
{
    ++g_checks;
    if (!ok) ++g_failures;
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what,
                detail[0] ? " -- " : "", detail);
}

static const char* rdma_err(int32_t rc)
{
    switch (rc) {
        case easyrdma_Error_Success:                 return "Success";
        case easyrdma_Error_InvalidSession:          return "InvalidSession";
        case easyrdma_Error_InvalidArgument:         return "InvalidArgument";
        case easyrdma_Error_NotConnected:            return "NotConnected";
        case easyrdma_Error_AlreadyConfigured:       return "AlreadyConfigured";
        case easyrdma_Error_Disconnected:            return "Disconnected";
        case easyrdma_Error_Timeout:                 return "Timeout";
        case easyrdma_Error_OperationNotSupported:   return "OperationNotSupported";
        case easyrdma_Error_InvalidOperation:        return "InvalidOperation";
        case easyrdma_Error_SessionNotConfigured:    return "SessionNotConfigured";
        case easyrdma_Error_AddressInUse:            return "AddressInUse";
        case easyrdma_Error_UnableToConnect:         return "UnableToConnect";
        default:                                     return "(see easyrdma.h)";
    }
}

#define RDMA_OK(expr)                                                          \
    do {                                                                       \
        int32_t _rc = (expr);                                                  \
        if (_rc != easyrdma_Error_Success) {                                   \
            std::printf("  FATAL: %s -> %d (%s)\n", #expr, _rc, rdma_err(_rc));\
            char _buf[512] = {0};                                              \
            easyrdma_GetLastErrorString(_buf, sizeof _buf);                    \
            if (_buf[0]) std::printf("         %s\n", _buf);                   \
            ++g_failures;                                                      \
            return false;                                                      \
        }                                                                      \
    } while (0)

#define CUDA_OK(expr)                                                          \
    do {                                                                       \
        cudaError_t _e = (expr);                                               \
        if (_e != cudaSuccess) {                                               \
            std::printf("  FATAL: %s -> %s\n", #expr, cudaGetErrorString(_e));  \
            ++g_failures;                                                      \
            return false;                                                      \
        }                                                                      \
    } while (0)

// The GPU side of question C. Sums bytes through the device pointer. If the
// landing zone is not really GPU-visible this either faults or returns garbage.
__global__ void sum_bytes(const unsigned char* p, size_t n, unsigned long long* out)
{
    unsigned long long local = 0;
    for (size_t i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
         i += gridDim.x * (size_t)blockDim.x) {
        local += p[i];
    }
    atomicAdd(out, local);
}

// ---------------------------------------------------------------- the pool

struct Pool {
    unsigned char* host = nullptr;
    unsigned char* dev  = nullptr;
    size_t         size = 0;

    bool contains(const void* p, size_t n) const
    {
        const unsigned char* q = static_cast<const unsigned char*>(p);
        return q >= host && q + n <= host + size;
    }
};

// ---------------------------------------------------------------- the link

// One unidirectional easyrdma connection, both ends in this process, looped
// back through the local RoCE port. Receiver accepts, sender connects.
struct Link {
    easyrdma_Session listener = nullptr;
    easyrdma_Session rx       = nullptr;
    easyrdma_Session tx       = nullptr;
};

static bool link_up(Link& L, const std::string& addr, uint16_t port)
{
    RDMA_OK(easyrdma_CreateListenerSession(addr.c_str(), port, &L.listener));

    std::atomic<int32_t> accept_rc{easyrdma_Error_Success};
    easyrdma_Session accepted = nullptr;
    std::thread acceptor([&] {
        accept_rc = easyrdma_Accept(L.listener, easyrdma_Direction_Receive,
                                    10000, &accepted);
    });

    // Give the listener a moment to be ready before connecting into it.
    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    int32_t crc = easyrdma_CreateConnectorSession(addr.c_str(), 0, &L.tx);
    if (crc == easyrdma_Error_Success) {
        crc = easyrdma_Connect(L.tx, easyrdma_Direction_Send, addr.c_str(),
                               port, 10000);
    }
    acceptor.join();

    if (crc != easyrdma_Error_Success) {
        std::printf("  FATAL: connect -> %d (%s)\n", crc, rdma_err(crc));
        ++g_failures;
        return false;
    }
    if (accept_rc != easyrdma_Error_Success) {
        std::printf("  FATAL: accept -> %d (%s)\n", accept_rc.load(),
                    rdma_err(accept_rc.load()));
        ++g_failures;
        return false;
    }
    L.rx = accepted;
    return true;
}

static void link_down(Link& L)
{
    // DeferWhileUserBuffersOutstanding exists precisely because caller-owned
    // buffers can still be in flight at teardown. Closing without it while an
    // external region is queued is what made run 1 abort with "double free or
    // corruption" after the verdict had already printed.
    const uint32_t defer = easyrdma_CloseFlags_DeferWhileUserBuffersOutstanding;
    if (L.tx)       { easyrdma_AbortSession(L.tx);  easyrdma_CloseSession(L.tx, defer); }
    if (L.rx)       { easyrdma_AbortSession(L.rx);  easyrdma_CloseSession(L.rx, defer); }
    if (L.listener) { easyrdma_CloseSession(L.listener, defer); }
    L = Link{};
}

// Completion for an external buffer region. This is the only way to learn that
// a user-buffer transfer finished: RdmaBufferQueue::WaitForCompletedBuffer
// throws InvalidOperation when putBackToIdleOnCompletion is set, which it is
// for single-buffer external queues, so AcquireReceivedRegion is not available.
struct Completion {
    std::mutex              m;
    std::condition_variable cv;
    bool                    fired = false;
    int32_t                 status = 0;
    size_t                  bytes = 0;

    static void C_CONV trampoline(void* ctx1, void* /*ctx2*/, int32_t status,
                                  size_t completedBytes)
    {
        auto* self = static_cast<Completion*>(ctx1);
        {
            std::lock_guard<std::mutex> g(self->m);
            self->status = status;
            self->bytes  = completedBytes;
            self->fired  = true;
        }
        self->cv.notify_all();
    }

    bool wait(int ms)
    {
        std::unique_lock<std::mutex> g(m);
        return cv.wait_for(g, std::chrono::milliseconds(ms), [&] { return fired; });
    }
};

// Fill a send region with a recognisable pattern and queue it.
static bool send_one(easyrdma_Session tx, size_t n, unsigned char seed)
{
    easyrdma_InternalBufferRegion region{};
    RDMA_OK(easyrdma_AcquireSendRegion(tx, 5000, &region));
    if (region.bufferSize < n) {
        std::printf("  FATAL: send region %zu < %zu\n", region.bufferSize, n);
        ++g_failures;
        return false;
    }
    unsigned char* p = static_cast<unsigned char*>(region.buffer);
    for (size_t i = 0; i < n; ++i) p[i] = static_cast<unsigned char>(seed + (i & 0x3F));
    region.usedSize = n;
    RDMA_OK(easyrdma_QueueBufferRegion(tx, &region, nullptr));
    return true;
}

// ---------------------------------------------------------------- test A

static bool test_external(const Pool& pool, const std::string& addr,
                          uint16_t port, size_t msg, size_t offset)
{
    std::printf("\n=== A. ConfigureExternalBuffer over our cudaHostAlloc pool ===\n");

    Link L;
    if (!link_up(L, addr, port)) return false;

    // Poison the whole pool first. Anything that is still 0xAB afterwards was
    // not written, which is how we tell a real landing from a lucky-looking one.
    std::memset(pool.host, 0xAB, pool.size);

    int32_t rc = easyrdma_ConfigureExternalBuffer(L.rx, pool.host, pool.size, 4);
    std::printf("  ConfigureExternalBuffer(pool=%p, size=%zu, concurrent=4) -> %d (%s)\n",
                (void*)pool.host, pool.size, rc, rdma_err(rc));
    check(rc == easyrdma_Error_Success,
          "easyrdma accepts a cudaHostAlloc'd pointer as its landing zone");
    if (rc != easyrdma_Error_Success) { link_down(L); return false; }

    RDMA_OK(easyrdma_ConfigureBuffers(L.tx, msg, 4));

    // We choose the offset. That is the whole point: with external buffers the
    // slot is ours to pick, which is what makes a slot-per-message pool possible.
    unsigned char* target = pool.host + offset;

    Completion c1;
    easyrdma_BufferCompletionCallbackData cb1{};
    cb1.callbackFunction = &Completion::trampoline;
    cb1.context1 = &c1;
    cb1.context2 = nullptr;
    RDMA_OK(easyrdma_QueueExternalBufferRegion(L.rx, target, msg, &cb1, 5000));

    if (!send_one(L.tx, msg, 0x40)) { link_down(L); return false; }

    check(c1.wait(5000), "the completion callback fired");
    if (!c1.fired) { link_down(L); return false; }

    char cdet[128];
    std::snprintf(cdet, sizeof cdet, "status=%d bytes=%zu", c1.status, c1.bytes);
    check(c1.status == easyrdma_Error_Success, "the completion reports success", cdet);
    check(c1.bytes == msg, "the completion reports the full payload size", cdet);

    // Content: the payload landed where we asked, and nowhere else.
    bool payload_ok = true;
    for (size_t i = 0; i < msg; ++i) {
        if (target[i] != static_cast<unsigned char>(0x40 + (i & 0x3F))) {
            payload_ok = false;
            break;
        }
    }
    check(payload_ok, "the bytes at our chosen offset are the bytes that were sent");

    bool before_clean = true;
    for (size_t i = 0; i < offset; ++i)
        if (pool.host[i] != 0xAB) { before_clean = false; break; }
    bool after_clean = true;
    for (size_t i = offset + msg; i < pool.size; ++i)
        if (pool.host[i] != 0xAB) { after_clean = false; break; }
    check(before_clean, "the pool before the offset is untouched");
    check(after_clean, "the pool after the payload is untouched");

    // C. Can the GPU read it in place?
    unsigned long long* d_out = nullptr;
    CUDA_OK(cudaMalloc(&d_out, sizeof(unsigned long long)));
    CUDA_OK(cudaMemset(d_out, 0, sizeof(unsigned long long)));
    sum_bytes<<<32, 256>>>(pool.dev + offset, msg, d_out);
    CUDA_OK(cudaDeviceSynchronize());
    unsigned long long gpu_sum = 0;
    CUDA_OK(cudaMemcpy(&gpu_sum, d_out, sizeof gpu_sum, cudaMemcpyDeviceToHost));
    cudaFree(d_out);

    unsigned long long cpu_sum = 0;
    for (size_t i = 0; i < msg; ++i) cpu_sum += target[i];

    char detail[128];
    std::snprintf(detail, sizeof detail, "gpu=%llu cpu=%llu", gpu_sum, cpu_sum);
    check(gpu_sum == cpu_sum,
          "the GPU reads the received bytes in place, no copy", detail);

    // Ownership question (b) from the plan, answered cheaply here rather than
    // discovered during integration: is the slot credit returned automatically
    // on completion, or does it need an explicit release?
    uint64_t user_buffers = 0;
    size_t   sz = sizeof user_buffers;
    int32_t  prc = easyrdma_GetProperty(L.rx, easyrdma_Property_UserBuffers,
                                        &user_buffers, &sz);
    std::printf("  after completion: UserBuffers property -> rc %d, value %llu\n",
                prc, (unsigned long long)user_buffers);

    // Second message into a different slot, to show slots are reusable and
    // independently addressable rather than a one-shot trick.
    unsigned char* target2 = pool.host + offset + msg;
    Completion c2;
    easyrdma_BufferCompletionCallbackData cb2{};
    cb2.callbackFunction = &Completion::trampoline;
    cb2.context1 = &c2;
    RDMA_OK(easyrdma_QueueExternalBufferRegion(L.rx, target2, msg, &cb2, 5000));
    if (!send_one(L.tx, msg, 0x80)) { link_down(L); return false; }
    check(c2.wait(5000), "a second transfer completes");
    bool payload2_ok = c2.fired;
    for (size_t i = 0; payload2_ok && i < msg; ++i)
        if (target2[i] != static_cast<unsigned char>(0x80 + (i & 0x3F))) { payload2_ok = false; break; }
    check(payload2_ok, "the second payload lands correctly in a different slot we chose");
    check(target[0] == static_cast<unsigned char>(0x40),
          "the first slot still holds its own data, so slots do not alias");

    link_down(L);
    return true;
}

// ---------------------------------------------------------------- test B

static bool test_control(const Pool& pool, const std::string& addr,
                         uint16_t port, size_t msg)
{
    std::printf("\n=== B. CONTROL: plain ConfigureBuffers must NOT land in our pool ===\n");

    Link L;
    if (!link_up(L, addr, port)) return false;

    std::memset(pool.host, 0xCD, pool.size);

    RDMA_OK(easyrdma_ConfigureBuffers(L.rx, msg, 4));
    RDMA_OK(easyrdma_ConfigureBuffers(L.tx, msg, 4));

    if (!send_one(L.tx, msg, 0x11)) { link_down(L); return false; }

    easyrdma_InternalBufferRegion got{};
    RDMA_OK(easyrdma_AcquireReceivedRegion(L.rx, 5000, &got));

    std::printf("  region.buffer = %p (pool spans %p..%p)\n", got.buffer,
                (void*)pool.host, (void*)(pool.host + pool.size));

    check(!pool.contains(got.buffer, got.usedSize),
          "the stock path lands OUTSIDE our pool, as it must");

    bool pool_clean = true;
    for (size_t i = 0; i < pool.size; ++i)
        if (pool.host[i] != 0xCD) { pool_clean = false; break; }
    check(pool_clean, "our pool is entirely untouched by the stock path");

    // And the data did arrive, so this is a real transfer and not a no-op that
    // trivially satisfies the two checks above.
    bool arrived = true;
    const unsigned char* p = static_cast<const unsigned char*>(got.buffer);
    for (size_t i = 0; i < msg; ++i)
        if (p[i] != static_cast<unsigned char>(0x11 + (i & 0x3F))) { arrived = false; break; }
    check(arrived, "the stock path did transfer the data, so the control is live");

    RDMA_OK(easyrdma_ReleaseReceivedBufferRegion(L.rx, &got));
    link_down(L);
    return true;
}

// ---------------------------------------------------------------- test D

static bool test_polling_conflict(const Pool& pool, const std::string& addr,
                                  uint16_t port)
{
    std::printf("\n=== D. PREDICTED FAILURE: polling + external buffers ===\n");
    std::printf("  Source says RdmaConnectedSessionBase.cpp:153 throws\n");
    std::printf("  OperationNotSupported (%d) when usePolling is set. Confirming.\n",
                easyrdma_Error_OperationNotSupported);

    Link L;
    if (!link_up(L, addr, port)) return false;

    uint8_t on = 1;
    int32_t src = easyrdma_SetProperty(L.rx, easyrdma_Property_UseRxPolling,
                                       &on, sizeof on);
    check(src == easyrdma_Error_Success, "RX polling can be enabled before configure");

    int32_t rc = easyrdma_ConfigureExternalBuffer(L.rx, pool.host, pool.size, 4);
    std::printf("  ConfigureExternalBuffer with polling on -> %d (%s)\n",
                rc, rdma_err(rc));
    check(rc == easyrdma_Error_OperationNotSupported,
          "polling and external buffers are mutually exclusive, as the source says");

    link_down(L);
    return true;
}

// ---------------------------------------------------------------- main

int main(int argc, char** argv)
{
    // Unbuffered, because when this program dies it dies by abort() and a
    // buffered stdout takes the evidence with it.
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    std::string addr = "192.168.20.1";
    uint16_t    port = 18600;
    size_t      msg  = 1u << 20;   // 1 MiB
    size_t      pool_size = 64u << 20;
    size_t      offset = 4u << 20;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> const char* { return (i + 1 < argc) ? argv[++i] : ""; };
        if      (a == "--addr")   addr = next();
        else if (a == "--port")   port = static_cast<uint16_t>(std::atoi(next()));
        else if (a == "--msg")    msg = static_cast<size_t>(std::atoll(next()));
        else if (a == "--pool")   pool_size = static_cast<size_t>(std::atoll(next()));
        else if (a == "--offset") offset = static_cast<size_t>(std::atoll(next()));
        else { std::printf("unknown arg: %s\n", a.c_str()); return 2; }
    }

    std::printf("gate5_extbuf: does easyrdma land RDMA writes in memory we allocated?\n");
    std::printf("  addr=%s port=%u msg=%zu pool=%zu offset=%zu\n\n",
                addr.c_str(), port, msg, pool_size, offset);

    Pool pool;
    pool.size = pool_size;
    void* h = nullptr;
    cudaError_t ce = cudaHostAlloc(&h, pool.size,
                                   cudaHostAllocMapped | cudaHostAllocPortable);
    if (ce != cudaSuccess) {
        std::printf("  FATAL: cudaHostAlloc -> %s\n", cudaGetErrorString(ce));
        return 1;
    }
    pool.host = static_cast<unsigned char*>(h);
    void* d = nullptr;
    ce = cudaHostGetDevicePointer(&d, h, 0);
    if (ce != cudaSuccess) {
        std::printf("  FATAL: cudaHostGetDevicePointer -> %s\n", cudaGetErrorString(ce));
        return 1;
    }
    pool.dev = static_cast<unsigned char*>(d);

    std::printf("=== the pool ===\n");
    std::printf("  host %p  device %p  size %zu\n", (void*)pool.host,
                (void*)pool.dev, pool.size);
    check((void*)pool.host == (void*)pool.dev,
          "host VA == device VA (expected on GB10's coherent C2C)");

    // Each test gets its own port so a half-torn-down listener from a previous
    // test cannot be mistaken for the current one.
    test_external(pool, addr, port, msg, offset);
    test_control(pool, addr, static_cast<uint16_t>(port + 2), msg);
    test_polling_conflict(pool, addr, static_cast<uint16_t>(port + 4));

    std::printf("\n=== verdict ===\n");
    std::printf("  %d checks, %d failures\n", g_checks, g_failures);
    std::printf("  GATE 5: %s\n", g_failures == 0 ? "PASS" : "FAIL");

    cudaFreeHost(pool.host);
    return g_failures == 0 ? 0 : 1;
}
