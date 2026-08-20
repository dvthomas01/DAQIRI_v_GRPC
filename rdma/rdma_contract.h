#pragma once
//
// rdma_contract.h — the agreement between the Phase 2 sender and receiver.
//
// This exists as its own header for one reason.  The verification works by
// having the receiver predict the payload from the sequence number and check
// that prediction against the spectrum.  If the two sides ever disagreed about
// what tone belongs to sequence n, the test would fail in the correct-ordering
// run and, worse, could pass in the broken-ordering run.  A duplicated
// three-line function in two separately compiled programs is exactly how that
// disagreement arrives.  One definition, shared by both.
//
// No CUDA and no verbs here: the PXI compiles this too.

#include <cstdint>

namespace contract {

// Receiver drives the exchange.  It poisons a slot, posts a receive, and sends
// one of these; the sender writes that slot and nothing else.  Strict lockstep,
// one message in flight.  This is a correctness harness, so determinism is
// worth more than throughput.
struct Credit {
    uint32_t seq;         // message number within the current size phase
    uint32_t slot;        // pool slot to write into
    uint32_t n_samples;   // floats to write
    uint32_t stop;        // 1 = the run is over
    uint64_t remote_off;  // byte offset of that slot from pool_addr
};

inline constexpr float kSampleRateHz = 1'000'000.0f;

// The payload tone changes every message: 10 kHz to 85 kHz in 5 kHz steps.
//
// The variation is the point.  A fixed payload would let the receiver verify
// clean against the previous message's leftover bytes, which is precisely the
// stale-data case the broken-ordering test is trying to expose.  The 5 kHz step
// is far larger than the coarsest bin in the sweep (244 Hz at 4096 samples), so
// neighbouring sequence numbers are never confusable, and 85 kHz is well under
// Nyquist so nothing aliases.
inline float payload_tone_hz(uint32_t seq) {
    return 10'000.0f + static_cast<float>(seq % 16u) * 5'000.0f;
}

// Written into a slot before each message.  A real tone at a frequency no
// payload ever uses, so a transform that ran too early reports as a specific
// recognisable number instead of as a vaguely wrong one.
inline constexpr float kPoisonToneHz = 400'000.0f;

// ─────────────────────────────────────────────────────────────────────────────
// Phase 3 step 5: the external-buffer frame
//
// Phase 2 drove the exchange with a TCP credit and a separate Credit struct,
// because the receiver chose the slot.  That is not how this works any more.
// easyrdma chooses the slot, the sender just sends, and the only flow control
// is that a slot cannot be written until the receiver re-queues it.  So the
// sequence number has to travel in the payload itself.
//
// The header is deliberately not adjacent to the samples.  kPayloadOffset puts
// the float array on a 256-byte boundary within the slot, so that given a
// page-aligned pool and a slot size that is a multiple of the offset, every
// payload cuFFT sees is 256-byte aligned.  cuFFT rejects under-aligned input
// with CUFFT_INVALID_VALUE rather than merely running slower, and a 240-byte
// hole per message is not worth arguing about.
struct ExtFrameHeader {
    uint32_t magic;      // kExtMagic, so a stale or truncated slot is obvious
    uint32_t seq;        // message number; selects the tone via payload_tone_hz
    uint32_t n_samples;  // floats that follow at kPayloadOffset
    uint32_t flags;      // bit 0 = last message of the run
};

inline constexpr uint32_t kExtMagic      = 0x44415149u;  // 'DAQI'
inline constexpr uint32_t kExtFlagLast   = 1u;
inline constexpr size_t   kPayloadOffset = 256;

inline size_t ext_frame_bytes(uint32_t n_samples) {
    return kPayloadOffset + static_cast<size_t>(n_samples) * sizeof(float);
}

}  // namespace contract
