#include "cufft_executor.h"

#include <cmath>
#include <algorithm>
#include <stdexcept>
#include <string>

// ---- Error-checking macros ------------------------------------------------

#define CUDA_CHECK(expr)                                                        \
    do {                                                                        \
        cudaError_t _err = (expr);                                              \
        if (_err != cudaSuccess) {                                              \
            throw std::runtime_error(                                           \
                std::string("CUDA error in " __FILE__ ":")                      \
                + std::to_string(__LINE__) + ": "                               \
                + cudaGetErrorString(_err));                                    \
        }                                                                       \
    } while (0)

#define CUFFT_CHECK(expr)                                                       \
    do {                                                                        \
        cufftResult _r = (expr);                                                \
        if (_r != CUFFT_SUCCESS) {                                              \
            throw std::runtime_error(                                           \
                std::string("cuFFT error in " __FILE__ ":")                     \
                + std::to_string(__LINE__) + ": code "                          \
                + std::to_string(static_cast<int>(_r)));                        \
        }                                                                       \
    } while (0)

// ---- CuFFTExecutor --------------------------------------------------------

CuFFTExecutor::CuFFTExecutor(int n, bool own_stream) : n_(n) {
    CUFFT_CHECK(cufftPlan1d(&plan_, n_, CUFFT_R2C, 1));
    if (own_stream) {
        // cudaStreamNonBlocking so this stream never implicitly synchronises
        // with the legacy null stream used elsewhere in the process.
        CUDA_CHECK(cudaStreamCreateWithFlags(&stream_, cudaStreamNonBlocking));
        CUFFT_CHECK(cufftSetStream(plan_, stream_));
        own_stream_ = true;
    }
    // cudaEventDisableTiming would be cheaper, but last_exec_us() needs the
    // timestamps, so keep timing enabled and accept the small record cost.
    CUDA_CHECK(cudaEventCreate(&ev_start_));
    CUDA_CHECK(cudaEventCreate(&ev_stop_));
}

CuFFTExecutor::~CuFFTExecutor() {
    cufftDestroy(plan_);
    cudaEventDestroy(ev_start_);
    cudaEventDestroy(ev_stop_);
    if (own_stream_ && stream_) cudaStreamDestroy(stream_);
}

void CuFFTExecutor::execute(const float* d_input, cufftComplex* d_output) {
    CUDA_CHECK(cudaEventRecord(ev_start_, stream_));
    // cufftExecR2C requires a non-const input pointer (in-place transforms
    // modify the input buffer); we guarantee d_input is not reused before
    // the next synchronize, so the cast is safe.
    CUFFT_CHECK(cufftExecR2C(plan_,
                              const_cast<cufftReal*>(d_input),
                              d_output));
    CUDA_CHECK(cudaEventRecord(ev_stop_, stream_));
    if (own_stream_) {
        // Spin instead of blocking.  cudaEventSynchronize parks the thread and
        // pays a scheduler wakeup on completion; at these durations (tens of
        // us) that wakeup is a measurable part of the residual.
        cudaError_t q;
        while ((q = cudaEventQuery(ev_stop_)) == cudaErrorNotReady) { }
        CUDA_CHECK(q);
    } else {
        CUDA_CHECK(cudaEventSynchronize(ev_stop_));
    }

    float ms = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&ms, ev_start_, ev_stop_));
    last_exec_us_ = ms * 1000.0f;  // ms → µs
}

bool CuFFTExecutor::try_execute(const float* d_input, cufftComplex* d_output) {
    CUDA_CHECK(cudaEventRecord(ev_start_, stream_));
    cufftResult r = cufftExecR2C(plan_,
                                 const_cast<cufftReal*>(d_input),
                                 d_output);
    if (r != CUFFT_SUCCESS) {
        (void)cudaGetLastError();  // clear any sticky error the failure left
        return false;
    }
    CUDA_CHECK(cudaEventRecord(ev_stop_, stream_));
    cudaError_t serr = cudaEventSynchronize(ev_stop_);
    if (serr != cudaSuccess) {
        (void)cudaGetLastError();
        return false;
    }
    float ms = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&ms, ev_start_, ev_stop_));
    last_exec_us_ = ms * 1000.0f;
    return true;
}

// ---- SM-based realign copy (E3) -------------------------------------------

__global__ void realign_copy_f2(float2* __restrict__ dst,
                                const float2* __restrict__ src,
                                size_t n2) {
    size_t       i      = blockIdx.x * static_cast<size_t>(blockDim.x) + threadIdx.x;
    const size_t stride = static_cast<size_t>(gridDim.x) * blockDim.x;
    for (; i < n2; i += stride) dst[i] = src[i];
}

void launch_realign_copy(float* dst, const float* src, size_t n_floats,
                         cudaStream_t stream) {
    const size_t n2 = n_floats / 2;   // float2 = 8 B, matches the 8-B alignment
    if (n2 > 0) {
        const int threads = 256;
        size_t    want    = (n2 + threads - 1) / threads;
        const int blocks  = static_cast<int>(want > 4096 ? 4096 : want);
        realign_copy_f2<<<blocks, threads, 0, stream>>>(
            reinterpret_cast<float2*>(dst),
            reinterpret_cast<const float2*>(src), n2);
        // A launch failure here is silent: dst keeps its previous contents and
        // the FFT happily transforms stale/zero data, which looks like a fast
        // but wrong result.  Fail loudly instead.
        CUDA_CHECK(cudaGetLastError());
    }
    if (n_floats & 1) {  // odd tail; never hit for power-of-two buffers
        CUDA_CHECK(cudaMemcpyAsync(dst + n_floats - 1, src + n_floats - 1,
                                   sizeof(float), cudaMemcpyDefault, stream));
    }
}

std::vector<std::pair<float, float>> CuFFTExecutor::detect_peaks(
    const cufftComplex* d_output,
    int                 k,
    float               sample_rate_hz) const
{
    const int n_bins = n_ / 2 + 1;

    // Copy output to host
    std::vector<cufftComplex> h_out(n_bins);
    CUDA_CHECK(cudaMemcpy(h_out.data(), d_output,
                          static_cast<size_t>(n_bins) * sizeof(cufftComplex),
                          cudaMemcpyDeviceToHost));

    // Compute normalised magnitude for each bin.
    // For a real-input R2C transform: magnitude = |X[k]| * 2/N
    // (the factor of 2 restores the energy lost in the one-sided spectrum,
    //  except for the DC and Nyquist bins which are not doubled).
    const float norm = 2.0f / static_cast<float>(n_);
    std::vector<std::pair<float, float>> bins;
    bins.reserve(n_bins);

    for (int i = 0; i < n_bins; ++i) {
        const float re  = h_out[i].x;
        const float im  = h_out[i].y;
        const float mag = std::sqrt(re * re + im * im) * norm;
        const float freq_hz = static_cast<float>(i) * sample_rate_hz
                              / static_cast<float>(n_);
        bins.emplace_back(freq_hz, mag);
    }

    // Partial sort: top-k by magnitude descending
    if (k > n_bins) k = n_bins;
    std::partial_sort(bins.begin(), bins.begin() + k, bins.end(),
        [](const auto& a, const auto& b) { return a.second > b.second; });
    bins.resize(k);
    return bins;
}
