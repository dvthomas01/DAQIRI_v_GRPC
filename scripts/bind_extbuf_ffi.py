#!/usr/bin/env python3
"""Bind the easyrdma external-buffer entry points in grpc-direct's FFI block.

Two functions, not three. Gate 5 established that ReleaseUserBufferRegionToIdle
is not on this path: ConfigureExternalBuffer never sets autoQueueRx, so
QueueExternalBufferRegion is both the re-arm and the credit, and the
UserBuffers property reads 0 after a completion with no release call.

Idempotent: re-running is a no-op.
"""
import re
import sys
import pathlib

LIB = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                   pathlib.Path.home() / "grpc-direct" / "src" / "lib.rs")

src = LIB.read_text()

if "easyrdma_ConfigureExternalBuffer" in src:
    print("SKIP: bindings already present")
    sys.exit(0)

CONSTS_ANCHOR = """    pub const PROPERTY_USE_RX_POLLING: u32 = 0x103;
"""

CONSTS_NEW = """    pub const PROPERTY_USE_RX_POLLING: u32 = 0x103;
    /// uint64_t. Reads back the number of user buffers still outstanding.
    /// Gate 5: this is 0 immediately after a completion callback fires, which
    /// is the evidence that no release call is required on this path.
    pub const PROPERTY_USER_BUFFERS: u32 = 0x102;

    /// Close flag. Mandatory when external buffers are in use: closing a
    /// session with a queued external region corrupts the heap. Gate 5 run 1
    /// aborted with "double free or corruption (fasttop)" without it.
    pub const CLOSE_DEFER_WHILE_USER_BUFFERS_OUTSTANDING: u32 = 0x01;
"""

ERRORS_ANCHOR = """    /// easyrdma session was disconnected by the peer.
    pub const ERROR_DISCONNECTED: i32 = -734017;
"""

ERRORS_NEW = """    /// easyrdma session was disconnected by the peer.
    pub const ERROR_DISCONNECTED: i32 = -734017;
    /// Returned by AcquireReceivedRegion on an external-buffer session. The
    /// external path is callback-driven and has no acquire step.
    pub const ERROR_INVALID_OPERATION: i32 = -734004;
    /// Buffers already configured; ConfigureExternalBuffer and
    /// ConfigureBuffers are mutually exclusive on one session.
    pub const ERROR_ALREADY_CONFIGURED: i32 = -734016;
    /// Returned when RX polling is enabled and external buffers are then
    /// configured. The two are mutually exclusive.
    pub const ERROR_OPERATION_NOT_SUPPORTED: i32 = -734026;
"""

# The callback type and its data struct. Argument ORDER matters and is not the
# order a reader would guess: status and byte count come last, after both
# context pointers.
CALLBACK_DECL = """
    /// `void (*)(void* context1, void* context2, int32_t status, size_t bytes)`
    ///
    /// Note the order: both contexts first, then status, then the byte count.
    pub type BufferCompletionCallback = unsafe extern "C" fn(
        context1: *mut std::ffi::c_void,
        context2: *mut std::ffi::c_void,
        completion_status: i32,
        completed_bytes: usize,
    );

    /// `easyrdma_BufferCompletionCallbackData`. `Option<fn>` is
    /// null-pointer-optimised, so this matches the C layout exactly and a
    /// `None` callback is a null function pointer.
    #[repr(C)]
    pub struct BufferCompletionCallbackData {
        pub callback_function: Option<BufferCompletionCallback>,
        pub context1: *mut std::ffi::c_void,
        pub context2: *mut std::ffi::c_void,
    }

    impl Default for BufferCompletionCallbackData {
        fn default() -> Self {
            Self {
                callback_function: None,
                context1: std::ptr::null_mut(),
                context2: std::ptr::null_mut(),
            }
        }
    }

    #[link(name = "easyrdma")]
"""

FN_ANCHOR = """        pub fn easyrdma_AbortSession(session: Session) -> i32;
"""

FN_NEW = """        /// Register one contiguous externally-owned region as the whole
        /// buffer pool. Mutually exclusive with `easyrdma_ConfigureBuffers`
        /// and with RX polling.
        pub fn easyrdma_ConfigureExternalBuffer(
            session: Session,
            external_buffer: *mut std::ffi::c_void,
            buffer_size: usize,
            max_concurrent_transactions: usize,
        ) -> i32;

        /// Queue a sub-range of the registered pool to receive into. This is
        /// the only re-arm and also the flow-control credit: unlike
        /// `ConfigureBuffers`, the external path never sets `autoQueueRx`, so
        /// nothing is queued unless this is called.
        pub fn easyrdma_QueueExternalBufferRegion(
            session: Session,
            pointer_within_buffer: *mut std::ffi::c_void,
            size: usize,
            callback_data: *mut BufferCompletionCallbackData,
            timeout_ms: i32,
        ) -> i32;

        pub fn easyrdma_AbortSession(session: Session) -> i32;
"""

for anchor, new in ((CONSTS_ANCHOR, CONSTS_NEW),
                    (ERRORS_ANCHOR, ERRORS_NEW),
                    (FN_ANCHOR, FN_NEW)):
    if src.count(anchor) != 1:
        sys.exit(f"FAIL: anchor appears {src.count(anchor)} times:\n{anchor}")
    src = src.replace(anchor, new)

if src.count('    #[link(name = "easyrdma")]\n') != 1:
    sys.exit("FAIL: #[link] anchor is not unique")
src = src.replace('    #[link(name = "easyrdma")]\n', CALLBACK_DECL)

LIB.write_text(src)
print(f"OK: patched {LIB}")
