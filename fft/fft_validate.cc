// fft_validate.cc — standalone correctness test for CuFFTExecutor + signal_gen.
//
// Generates a known multi-tone signal, runs it through cuFFT, and asserts that
// every injected frequency is detected within ±(sample_rate / N / 2) Hz.
// Also dumps the full magnitude spectrum to data/spectrum_N<N>.csv for plotting.
//
// Exit 0 = PASS.  Exit 1 = FAIL or CUDA error.

#include "cufft_executor.h"
#include "signal_gen.h"

#include <cuda_runtime.h>
#include <cmath>
#include <iostream>
#include <fstream>
#include <filesystem>
#include <vector>
#include <iomanip>

// ---- helpers ---------------------------------------------------------------

#define CUDA_CHECK_RET(expr)                                                    \
    do {                                                                        \
        cudaError_t _e = (expr);                                                \
        if (_e != cudaSuccess) {                                                \
            std::cerr << "CUDA error: " << cudaGetErrorString(_e)               \
                      << " (" __FILE__ ":" << __LINE__ << ")\n";                \
            return 1;                                                           \
        }                                                                       \
    } while (0)

static bool freq_detected(
    const std::vector<std::pair<float,float>>& peaks,
    float target_hz,
    float tolerance_hz)
{
    for (const auto& [freq, mag] : peaks) {
        if (std::abs(freq - target_hz) <= tolerance_hz) return true;
    }
    return false;
}

// Dump the full R2C output spectrum to a CSV for Python plotting.
// Columns: bin_index, frequency_hz, magnitude
static void dump_spectrum_csv(
    const cufftComplex* d_output,
    int                 n,
    float               sample_rate_hz,
    const std::string&  path)
{
    const int n_bins = n / 2 + 1;
    std::vector<cufftComplex> h_out(n_bins);
    cudaMemcpy(h_out.data(), d_output,
               static_cast<size_t>(n_bins) * sizeof(cufftComplex),
               cudaMemcpyDeviceToHost);

    std::filesystem::path p(path);
    if (p.has_parent_path())
        std::filesystem::create_directories(p.parent_path());

    std::ofstream f(path);
    f << "bin_index,frequency_hz,magnitude\n";
    const float norm = 2.0f / static_cast<float>(n);
    for (int i = 0; i < n_bins; ++i) {
        const float re   = h_out[i].x;
        const float im   = h_out[i].y;
        const float mag  = std::sqrt(re * re + im * im) * norm;
        const float freq = static_cast<float>(i) * sample_rate_hz
                           / static_cast<float>(n);
        f << i << ',' << freq << ',' << mag << '\n';
    }
    std::cout << "  Spectrum CSV : " << path << "\n";
}

// ---- main ------------------------------------------------------------------

int main() {
    constexpr float SAMPLE_RATE_HZ = 1'000'000.0f;  // 1 MHz
    constexpr int   N              = 16384;
    constexpr int   K_PEAKS        = 6;              // top-K bins to inspect

    const std::vector<float> input_freqs_hz = {500.0f, 1200.0f, 2500.0f};
    const float tolerance_hz = SAMPLE_RATE_HZ / static_cast<float>(N) / 2.0f;

    std::cout << "==== FFT Validation ====\n"
              << "  N            = " << N << " samples\n"
              << "  sample_rate  = " << SAMPLE_RATE_HZ / 1e3f << " kHz\n"
              << "  frequency_resolution = " << SAMPLE_RATE_HZ / N << " Hz/bin\n"
              << "  tolerance    = ±" << tolerance_hz << " Hz\n"
              << "  input tones  = ";
    for (float f : input_freqs_hz) std::cout << f << " Hz  ";
    std::cout << "\n\n";

    // Build signal
    SignalConfig cfg;
    cfg.sample_rate_hz = SAMPLE_RATE_HZ;
    cfg.buffer_size    = N;
    cfg.freqs_hz       = input_freqs_hz;
    cfg.amplitudes     = {1.2f, 0.6f, 0.3f};
    cfg.phases_rad     = {};        // zero phase
    cfg.noise_sigma    = 0.0f;      // no noise for validation

    std::vector<float> h_signal = make_signal(cfg);

    // Allocate device memory
    float*        d_input  = nullptr;
    cufftComplex* d_output = nullptr;
    CUDA_CHECK_RET(cudaMalloc(&d_input,  static_cast<size_t>(N) * sizeof(float)));
    CUDA_CHECK_RET(cudaMalloc(&d_output, static_cast<size_t>(N / 2 + 1) * sizeof(cufftComplex)));

    // Copy host signal to device
    CUDA_CHECK_RET(cudaMemcpy(d_input, h_signal.data(),
                              static_cast<size_t>(N) * sizeof(float),
                              cudaMemcpyHostToDevice));

    bool all_pass = false;
    try {
        CuFFTExecutor fft(N);

        // Warm-up pass (first cuFFT call can include JIT overhead)
        fft.execute(d_input, d_output);
        std::cout << "  Warm-up FFT exec time : " << fft.last_exec_us() << " µs\n";

        // Measurement pass
        fft.execute(d_input, d_output);
        std::cout << "  Measured FFT exec time: " << fft.last_exec_us() << " µs\n\n";

        // Dump full spectrum to CSV (for plot_spectrum.py)
        const std::string spectrum_path = "data/spectrum_N" + std::to_string(N) + ".csv";
        dump_spectrum_csv(d_output, N, SAMPLE_RATE_HZ, spectrum_path);
        std::cout << "\n";

        auto peaks = fft.detect_peaks(d_output, K_PEAKS, SAMPLE_RATE_HZ);

        std::cout << "  Top-" << K_PEAKS << " detected peaks:\n";
        std::cout << std::fixed << std::setprecision(1);
        for (const auto& [freq, mag] : peaks) {
            std::cout << "    " << std::setw(9) << freq << " Hz   mag = "
                      << std::setprecision(4) << mag << "\n";
        }
        std::cout << "\n";

        // Assert each injected frequency is present
        all_pass = true;
        for (float f : input_freqs_hz) {
            bool found = freq_detected(peaks, f, tolerance_hz);
            std::cout << "  " << std::setw(7) << std::setprecision(1) << f
                      << " Hz : " << (found ? "PASS" : "FAIL") << "\n";
            if (!found) all_pass = false;
        }

    } catch (const std::exception& ex) {
        std::cerr << "\nException: " << ex.what() << "\n";
        cudaFree(d_input);
        cudaFree(d_output);
        return 1;
    }

    cudaFree(d_input);
    cudaFree(d_output);

    std::cout << "\n==== " << (all_pass ? "VALIDATION PASSED" : "VALIDATION FAILED") << " ====\n";
    return all_pass ? 0 : 1;
}
