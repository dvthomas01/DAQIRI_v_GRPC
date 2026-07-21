#pragma once

#include <cufft.h>
#include <cuda_runtime.h>
#include <vector>
#include <utility>
#include <stdexcept>
#include <string>

// Manages a single cuFFT real-to-complex (R2C) plan for 1D transforms of size n.
//
// GPU timing is done via CUDA events so it is independent of host-side clocks.
// detect_peaks() copies the output back to host and is intended for validation
// and debugging only — do not call it in the hot benchmark path.
class CuFFTExecutor {
public:
    // Creates a 1D R2C plan for transforms of size n.
    // Throws std::runtime_error on cuFFT or CUDA failure.
    explicit CuFFTExecutor(int n);
    ~CuFFTExecutor();

    // Non-copyable
    CuFFTExecutor(const CuFFTExecutor&)            = delete;
    CuFFTExecutor& operator=(const CuFFTExecutor&) = delete;

    // Execute R2C FFT: d_input[n] (float) → d_output[n/2+1] (cufftComplex).
    // Both pointers must be valid CUDA device pointers.
    // Blocks until execution is complete and updates last_exec_us().
    void execute(const float* d_input, cufftComplex* d_output);

    // GPU execution time of the last execute() call, in microseconds.
    float last_exec_us() const { return last_exec_us_; }

    // Find the top-k frequency components in d_output (device pointer).
    // Returns a vector of (frequency_hz, normalised_magnitude) pairs,
    // sorted by magnitude descending.
    // Copies d_output to host internally — not for use in the hot path.
    std::vector<std::pair<float, float>> detect_peaks(
        const cufftComplex* d_output,
        int                 k,
        float               sample_rate_hz) const;

    int n() const { return n_; }

private:
    int         n_;
    cufftHandle plan_;
    cudaEvent_t ev_start_;
    cudaEvent_t ev_stop_;
    float       last_exec_us_ = 0.0f;
};
