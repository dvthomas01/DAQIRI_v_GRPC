#pragma once

#include <vector>

// Configuration for the synthetic multi-tone signal generator.
struct SignalConfig {
    float sample_rate_hz = 1'000'000.0f;  // 1 MHz default
    int   buffer_size    = 16384;          // samples per buffer

    // Parallel arrays — must all have the same length.
    std::vector<float> freqs_hz;           // e.g. {400.0f, 700.0f, 1800.0f}
    std::vector<float> amplitudes;         // e.g. {1.2f, 0.6f, 0.3f}
    std::vector<float> phases_rad;         // e.g. {0.0f, 0.0f, 0.0f}
                                           // Leave empty for zero phase on all tones.
    float noise_sigma = 0.0f;             // Std-dev of additive Gaussian noise (0 = no noise)
};

// Fill out[0..n-1] with a multi-tone signal according to cfg.
// out must be pre-allocated (at least n floats).
void generate_signal(const SignalConfig& cfg, float* out, int n);

// Convenience wrapper: allocates and returns a std::vector<float> of length cfg.buffer_size.
std::vector<float> make_signal(const SignalConfig& cfg);
