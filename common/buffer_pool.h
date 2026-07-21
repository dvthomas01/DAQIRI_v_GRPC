#pragma once

#include <cuda_runtime.h>
#include <vector>
#include <stdexcept>
#include <string>

// Pre-allocated ring of CUDA device float buffers.
// Avoids cudaMalloc on the hot path by pre-allocating N_SLOTS device buffers
// at startup and cycling through them round-robin.
//
// Usage:
//   DeviceBufferPool pool(8, 16384);   // 8 slots × 16384 floats each
//   float* d_buf = pool.next_slot();   // get next slot (non-blocking)
//   // ... fill d_buf on device ...
//   // On the next iteration the same slot may be reused once the GPU is done.
//
// Thread safety: next_slot() is NOT thread-safe. Call from a single producer.
class DeviceBufferPool {
public:
    DeviceBufferPool(int n_slots, int floats_per_slot)
        : n_slots_(n_slots)
        , floats_per_slot_(floats_per_slot)
        , cursor_(0)
    {
        slots_.resize(n_slots_);
        for (int i = 0; i < n_slots_; ++i) {
            cudaError_t err = cudaMalloc(
                &slots_[i],
                static_cast<size_t>(floats_per_slot_) * sizeof(float));
            if (err != cudaSuccess) {
                for (int j = 0; j < i; ++j) cudaFree(slots_[j]);
                throw std::runtime_error(
                    std::string("DeviceBufferPool: cudaMalloc failed: ")
                    + cudaGetErrorString(err));
            }
        }
    }

    ~DeviceBufferPool() {
        for (float* p : slots_) cudaFree(p);
    }

    // Non-copyable, non-movable
    DeviceBufferPool(const DeviceBufferPool&)            = delete;
    DeviceBufferPool& operator=(const DeviceBufferPool&) = delete;

    // Return the next device buffer in the ring.
    // The caller is responsible for ensuring the GPU is done with the
    // previous use of this slot before writing new data into it
    // (e.g. via cudaStreamSynchronize or cudaDeviceSynchronize).
    float* next_slot() {
        float* p = slots_[cursor_];
        cursor_  = (cursor_ + 1) % n_slots_;
        return p;
    }

    float* slot(int i)        const { return slots_[i]; }
    int    n_slots()           const { return n_slots_; }
    int    floats_per_slot()   const { return floats_per_slot_; }
    size_t bytes_per_slot()    const { return static_cast<size_t>(floats_per_slot_) * sizeof(float); }

private:
    int                 n_slots_;
    int                 floats_per_slot_;
    std::vector<float*> slots_;
    int                 cursor_;
};
