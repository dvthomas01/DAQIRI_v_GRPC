#include "signal_gen.h"

#include <cmath>
#include <random>
#include <stdexcept>

static constexpr float kTwoPi = 6.28318530717958647692f;

void generate_signal(const SignalConfig& cfg, float* out, int n) {
    if (cfg.freqs_hz.size() != cfg.amplitudes.size()) {
        throw std::invalid_argument("signal_gen: freqs_hz and amplitudes must have equal length");
    }
    if (!cfg.phases_rad.empty() && cfg.phases_rad.size() != cfg.freqs_hz.size()) {
        throw std::invalid_argument("signal_gen: phases_rad must be empty or same length as freqs_hz");
    }

    const float dt = 1.0f / cfg.sample_rate_hz;
    const int   nc = static_cast<int>(cfg.freqs_hz.size());

    // Seeded RNG for reproducible noise across calls with the same config.
    std::mt19937 rng(0xDAB1'F00D);
    std::normal_distribution<float> noise(0.0f, cfg.noise_sigma);

    for (int i = 0; i < n; ++i) {
        const float t = static_cast<float>(i) * dt;
        float s = 0.0f;
        for (int c = 0; c < nc; ++c) {
            const float phase = cfg.phases_rad.empty() ? 0.0f : cfg.phases_rad[c];
            s += cfg.amplitudes[c] * std::sin(kTwoPi * cfg.freqs_hz[c] * t + phase);
        }
        if (cfg.noise_sigma > 0.0f) {
            s += noise(rng);
        }
        out[i] = s;
    }
}

std::vector<float> make_signal(const SignalConfig& cfg) {
    std::vector<float> buf(cfg.buffer_size);
    generate_signal(cfg, buf.data(), cfg.buffer_size);
    return buf;
}
