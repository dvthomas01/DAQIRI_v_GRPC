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
    //
    // own_stream: run the transform on a dedicated non-blocking stream instead
    //   of the legacy null stream, and wait for completion by polling
    //   cudaEventQuery rather than blocking in cudaEventSynchronize.  The clock
    //   -fair sweep put the whole remaining gap to DAQiri in this path: the
    //   residual (e2e - fft) is 4.9 us for DAQiri and 7.1 us here, and DAQiri
    //   polls a CUDA event on its own stream.  Blocking sync parks the thread
    //   and pays a wakeup; spinning trades a busy core for latency.
    explicit CuFFTExecutor(int n, bool own_stream = false);
    ~CuFFTExecutor();

    // Non-copyable
    CuFFTExecutor(const CuFFTExecutor&)            = delete;
    CuFFTExecutor& operator=(const CuFFTExecutor&) = delete;

    // Execute R2C FFT: d_input[n] (float) → d_output[n/2+1] (cufftComplex).
    // Both pointers must be valid CUDA device pointers.
    // Blocks until execution is complete and updates last_exec_us().
    void execute(const float* d_input, cufftComplex* d_output);

    // Same as execute() but returns false instead of throwing when cuFFT
    // rejects the call (e.g. CUFFT_INVALID_VALUE for an under-aligned input).
    // Used to probe once, at runtime, whether a given input pointer is
    // acceptable, rather than guessing from a hard-coded alignment rule.
    // Any sticky CUDA error is cleared before returning false.
    bool try_execute(const float* d_input, cufftComplex* d_output);

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

    // The stream this executor runs on.  0 (legacy null stream) unless the
    // executor was constructed with own_stream.  Callers that enqueue their own
    // work ahead of the transform must use this stream, or the transform can
    // start before that work has finished.
    cudaStream_t stream() const { return stream_; }

private:
    int          n_;
    cufftHandle  plan_;
    cudaEvent_t  ev_start_;
    cudaEvent_t  ev_stop_;
    cudaStream_t stream_    = 0;      // 0 = legacy null stream
    bool         own_stream_ = false; // stream_ is ours to destroy
    float        last_exec_us_ = 0.0f;
};

// Copy n_floats from src to dst using the SMs instead of the copy engine.
//
// Phase 0 measured cudaMemcpyAsync out of mapped host memory at only ~52 GB/s,
// and both the D2D and H2D variants hit the same wall, so the copy engine is
// the limit.  A grid-stride kernel reads through the SMs' load paths instead.
// src must be at least 8-byte aligned (float2 loads); dst is assumed to come
// from cudaMalloc.  Enqueued on `stream`, no synchronisation.
void launch_realign_copy(float* dst, const float* src, size_t n_floats,
                         cudaStream_t stream);
