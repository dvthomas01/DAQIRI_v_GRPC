#pragma once
//
// grpc_direct_extbuf.h — declarations for the three entry points Phase 3 step 4
// added to grpc-direct, which are not in the vendor's include/grpc_direct.h.
//
// They exist in the library (fork commit f0f5341 on branch daqiri-extbuf,
// confirmed present with nm -D) but the fork's public C header was not updated,
// so a C or C++ consumer has no declaration for them.  Declaring them here
// unblocks the receiver without a second patch cycle on the Spark.
//
// This is a stopgap and should not survive.  A header that lives in the
// consumer rather than in the library is a header that can silently disagree
// with it: change a parameter in lib.rs and this file will keep compiling and
// start corrupting the stack.  Fold these into the fork's include/grpc_direct.h
// before the fork is offered upstream, and delete this file.
//
// The vendor header is still the source of truth for everything else, including
// the GrpcDirectTransport enum and the opaque handle typedefs, so it is
// included rather than duplicated.

#include <grpc_direct.h>

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Create an RDMA server that receives directly into a caller-owned pool.
//
// pool must stay mapped and untouched by the caller for the lifetime of the
// server.  On the DGX it is a cudaHostAlloc allocation; GB10 is coherent, so
// the address the NIC writes to and the address a kernel reads from are the
// same number.
//
// The pool is divided into pool_size / slot_size slots, all armed at create
// time.  transport must be GRPC_DIRECT_TRANSPORT_RDMA; the low-latency variant
// is rejected, because easyrdma will not enable RX polling on an externally
// buffered session.
//
// Blocks in accept() until a client connects, exactly like
// grpc_direct_server_create.  Returns NULL on failure.
GrpcDirectServer* grpc_direct_server_create_ext(
    const char*         service_name,
    GrpcDirectTransport transport,
    const char*         address,
    uint32_t            port,
    void*               pool,
    size_t              pool_size,
    size_t              slot_size);

// Receive from an externally buffered server.
//
// On success *request_ptr points inside the caller's pool and *slot_out is the
// slot index to hand back to grpc_direct_server_slot_requeue.  The pointer is
// valid until that call and not one instruction longer.
//
// Returns NULL on failure, including on peer disconnect, which arrives as a
// non-zero completion status rather than as a return code because the external
// path has no blocking acquire to return it from.
GrpcDirectActiveRequest* grpc_direct_server_receive_ext(
    GrpcDirectServer* handle,
    const uint8_t**   request_ptr,
    size_t*           request_size,
    size_t*           slot_out);

// Hand a slot back to the NIC.  This is the entire lifetime contract.
//
// Until this is called the payload is the caller's; after it, the NIC may
// overwrite it at any moment.  A caller with a GPU consumer must not call this
// until the consuming work has completed, which for an asynchronous launch
// means after a CUDA event recorded behind that work has been synchronised,
// not after the launch returns.
//
// Returns 0 on success, the easyrdma status on failure, or -1 if the handle or
// slot index is not valid.
int32_t grpc_direct_server_slot_requeue(GrpcDirectServer* handle, size_t slot);

#ifdef __cplusplus
}  // extern "C"
#endif
