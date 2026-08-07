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

CuFFTExecutor::CuFFTExecutor(int n) : n_(n) {
    CUFFT_CHECK(cufftPlan1d(&plan_, n_, CUFFT_R2C, 1));
    CUDA_CHECK(cudaEventCreate(&ev_start_));
    CUDA_CHECK(cudaEventCreate(&ev_stop_));
}

CuFFTExecutor::~CuFFTExecutor() {
    cufftDestroy(plan_);
    cudaEventDestroy(ev_start_);
    cudaEventDestroy(ev_stop_);
}

void CuFFTExecutor::execute(const float* d_input, cufftComplex* d_output) {
    CUDA_CHECK(cudaEventRecord(ev_start_));
    // cufftExecR2C requires a non-const input pointer (in-place transforms
    // modify the input buffer); we guarantee d_input is not reused before
    // the next synchronize, so the cast is safe.
    CUFFT_CHECK(cufftExecR2C(plan_,
                              const_cast<cufftReal*>(d_input),
                              d_output));
    CUDA_CHECK(cudaEventRecord(ev_stop_));
    CUDA_CHECK(cudaEventSynchronize(ev_stop_));

    float ms = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&ms, ev_start_, ev_stop_));
    last_exec_us_ = ms * 1000.0f;  // ms → µs
}

bool CuFFTExecutor::try_execute(const float* d_input, cufftComplex* d_output) {
    CUDA_CHECK(cudaEventRecord(ev_start_));
    cufftResult r = cufftExecR2C(plan_,
                                 const_cast<cufftReal*>(d_input),
                                 d_output);
    if (r != CUFFT_SUCCESS) {
        (void)cudaGetLastError();  // clear any sticky error the failure left
        return false;
    }
    CUDA_CHECK(cudaEventRecord(ev_stop_));
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
