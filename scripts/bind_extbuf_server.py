#!/usr/bin/env python3
"""Phase 3 step 4: add the external-buffer receive path to grpc-direct's lib.rs.

Same discipline as bind_extbuf_ffi.py. Every edit is anchored on text that must
appear exactly once, and the script exits non-zero the moment an anchor is
missing or ambiguous rather than guessing. Re-running is a no-op.

What this adds, and what it deliberately does not touch:

  * rdma_server_create is left byte-for-byte alone. rdma-stock has to stay
    measurable against exactly the code the earlier numbers came from, so the
    external path is a second create function rather than a branch inside the
    first one. The cost is about ninety duplicated lines of listener and accept
    handling; the benefit is that no measurement of the stock arm can be
    blamed on a flag we added.

  * rdma_server_reaccept IS modified, because it configures buffers a second
    time on reconnect and would otherwise quietly hand the session back to
    driver-allocated buffers. That failure is invisible: the transfers keep
    working, they just stop landing in our pool.

Usage:  python3 bind_extbuf_server.py [path/to/src/lib.rs]
"""

import os
import sys

DEFAULT = os.path.expanduser("~/grpc-direct/src/lib.rs")
MARKER = "grpc_direct_server_create_ext"


# ---------------------------------------------------------------------------
# 1. Pool machinery, inserted after the existing RDMA constants.
# ---------------------------------------------------------------------------

A1_OLD = """/// Number of concurrent in-flight RDMA buffers per direction.
#[cfg(feature = "rdma")]
const RDMA_MAX_CONCURRENT: usize = 4;
"""

A1_NEW = A1_OLD + '''
// -----------------------------------------------------------------------------
// External-buffer receive path
//
// The stock path calls easyrdma_ConfigureBuffers, which allocates and registers
// the receive buffers inside the driver and hands them out through
// AcquireReceivedRegion / ReleaseReceivedBufferRegion. Payloads land in memory
// grpc_direct does not own, so a CUDA consumer has to copy them.
//
// The external path registers one contiguous pool supplied by the caller. It is
// a different protocol, not a flag:
//
//   * Completion is callback-only. AcquireReceivedRegion returns
//     ERROR_INVALID_OPERATION on an externally-buffered session, because
//     RdmaBufferQueue::WaitForCompletedBuffer throws unconditionally when
//     putBackToIdleOnCompletion is set, and it is set for external queues.
//   * There is no release call. A slot returns to idle when its callback
//     fires, and QueueExternalBufferRegion is both the re-arm and the
//     flow-control credit. Nothing is received unless the caller re-queues.
//   * RX polling is rejected on an externally-buffered session, so
//     RdmaLowLatency cannot use this path.
//
// grpc_direct does not link CUDA and must not: the same library runs on the
// x86 PXI, which has no GPU. The pool is allocated by the caller, with
// cudaHostAlloc on the receiving host, and arrives here as a bare pointer.
// -----------------------------------------------------------------------------

#[cfg(feature = "rdma")]
struct ExtCompletion {
    slot: usize,
    bytes: usize,
    status: i32,
}

/// Shared between the easyrdma completion thread and whichever thread is
/// sitting in receive_ext. Reached from the callback through a raw pointer, so
/// the Arc has to outlive both sessions; see the Drop impl.
#[cfg(feature = "rdma")]
struct ExtRxShared {
    ready: std::sync::Mutex<std::collections::VecDeque<ExtCompletion>>,
    cv: std::sync::Condvar,
}

#[cfg(feature = "rdma")]
struct ExtRxPool {
    /// Caller-owned pool. Not freed here; the caller allocated it and the
    /// caller outlives the server.
    base: *mut std::ffi::c_void,
    pool_size: usize,
    slot_size: usize,
    slots: usize,
    /// One record per slot, boxed so the address handed to easyrdma never
    /// moves. easyrdma keeps the pointer until the completion fires, so this
    /// cannot be a Vec element that a reallocation could relocate.
    cbdata: Vec<Box<easyrdma::BufferCompletionCallbackData>>,
    shared: std::sync::Arc<ExtRxShared>,
}

/// Runs on an easyrdma internal thread. Does no allocation beyond the deque
/// push and never unwinds across the FFI boundary (the release profile sets
/// panic = "abort", and a poisoned mutex is recovered rather than unwrapped).
#[cfg(feature = "rdma")]
unsafe extern "C" fn ext_rx_completion(
    context1: *mut std::ffi::c_void,
    context2: *mut std::ffi::c_void,
    completion_status: i32,
    completed_bytes: usize,
) {
    if context1.is_null() {
        return;
    }
    let shared = &*(context1 as *const ExtRxShared);
    let comp = ExtCompletion {
        slot: context2 as usize,
        bytes: completed_bytes,
        status: completion_status,
    };
    {
        let mut q = match shared.ready.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        };
        q.push_back(comp);
    }
    shared.cv.notify_one();
}

/// Re-arm one slot. This is the credit: the peer cannot land another payload
/// in this slot until it returns ERROR_SUCCESS.
#[cfg(feature = "rdma")]
unsafe fn ext_queue_slot(pool: &mut ExtRxPool, session: easyrdma::Session, slot: usize) -> i32 {
    let ctx1 = std::sync::Arc::as_ptr(&pool.shared) as *mut std::ffi::c_void;
    let base = pool.base as *mut u8;
    let slot_size = pool.slot_size;

    let cb = &mut *pool.cbdata[slot];
    cb.callback_function = Some(ext_rx_completion);
    cb.context1 = ctx1;
    cb.context2 = slot as *mut std::ffi::c_void;

    easyrdma::easyrdma_QueueExternalBufferRegion(
        session,
        base.add(slot * slot_size) as *mut std::ffi::c_void,
        slot_size,
        cb as *mut easyrdma::BufferCompletionCallbackData,
        easyrdma::TIMEOUT_INFINITE,
    )
}

/// Register the pool on a receive session and arm every slot. Called once from
/// rdma_server_create_ext and again from rdma_server_reaccept, because the
/// session object is new after a reconnect and carries none of this.
#[cfg(feature = "rdma")]
unsafe fn ext_configure_rx(pool: &mut ExtRxPool, session: easyrdma::Session) -> bool {
    let rc = easyrdma::easyrdma_ConfigureExternalBuffer(
        session,
        pool.base,
        pool.pool_size,
        pool.slots,
    );
    if rc != easyrdma::ERROR_SUCCESS {
        eprintln!("grpc_direct: RDMA ConfigureExternalBuffer failed: {}", rc);
        return false;
    }

    // Completions left over from the previous connection refer to payloads that
    // no longer mean anything. Drop them before re-arming.
    {
        let mut q = match pool.shared.ready.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        };
        q.clear();
    }

    for slot in 0..pool.slots {
        let rc = ext_queue_slot(pool, session, slot);
        if rc != easyrdma::ERROR_SUCCESS {
            eprintln!(
                "grpc_direct: RDMA QueueExternalBufferRegion(slot {}) failed: {}",
                slot, rc
            );
            return false;
        }
    }
    true
}
'''


# ---------------------------------------------------------------------------
# 2. Backend field.
# ---------------------------------------------------------------------------

A2_OLD = """    /// Whether RX polling was enabled at create time (re-applied on re-accept).
    polling: bool,
}
"""

A2_NEW = """    /// Whether RX polling was enabled at create time (re-applied on re-accept).
    polling: bool,
    /// Set only by rdma_server_create_ext. Its presence is what selects the
    /// external protocol everywhere else, including on re-accept.
    ext: Option<ExtRxPool>,
}
"""


# ---------------------------------------------------------------------------
# 3. Re-accept. The bug this closes: without it a reconnect silently reverts to
#    driver-allocated buffers and the payload stops landing in our pool, while
#    every transfer still succeeds.
# ---------------------------------------------------------------------------

A3_OLD = """    if easyrdma_ConfigureBuffers(rx_session, RDMA_MAX_FRAME_SIZE, RDMA_MAX_CONCURRENT)
        != ERROR_SUCCESS
        || easyrdma_ConfigureBuffers(tx_session, RDMA_MAX_FRAME_SIZE, RDMA_MAX_CONCURRENT)
            != ERROR_SUCCESS
    {
        easyrdma_AbortSession(rx_session);
        easyrdma_CloseSession(rx_session, 0);
        easyrdma_AbortSession(tx_session);
        easyrdma_CloseSession(tx_session, 0);
        return false;
    }
"""

A3_NEW = """    // The receive session is re-created by Accept, so the external pool
    // registration does not survive the reconnect and has to be redone. If this
    // branch is ever dropped, the reconnected session falls back to
    // driver-allocated buffers and keeps working, which is exactly why the
    // failure would not show up in a throughput number.
    let rx_ok = if b.ext.is_some() {
        let mut pool = b.ext.take().expect("checked is_some");
        let ok = ext_configure_rx(&mut pool, rx_session);
        b.ext = Some(pool);
        ok
    } else {
        easyrdma_ConfigureBuffers(rx_session, RDMA_MAX_FRAME_SIZE, RDMA_MAX_CONCURRENT)
            == ERROR_SUCCESS
    };

    if !rx_ok
        || easyrdma_ConfigureBuffers(tx_session, RDMA_MAX_FRAME_SIZE, RDMA_MAX_CONCURRENT)
            != ERROR_SUCCESS
    {
        easyrdma_AbortSession(rx_session);
        easyrdma_CloseSession(rx_session, 0);
        easyrdma_AbortSession(tx_session);
        easyrdma_CloseSession(tx_session, 0);
        return false;
    }
"""


# ---------------------------------------------------------------------------
# 4. Stock construction site gains ext: None. This is the only line
#    rdma_server_create loses, and it changes no behaviour.
# ---------------------------------------------------------------------------

A4_OLD = """        Some(RdmaServerBackend {
            rx_session,
            tx_session,
            rx_listener,
            tx_listener,
            rx_region: None,
            stream_region: None,
            polling,
        })
"""

A4_NEW = """        Some(RdmaServerBackend {
            rx_session,
            tx_session,
            rx_listener,
            tx_listener,
            rx_region: None,
            stream_region: None,
            polling,
            ext: None,
        })
"""


# ---------------------------------------------------------------------------
# 5. rdma_server_create_ext, inserted ahead of rdma_client_create.
# ---------------------------------------------------------------------------

A5_OLD = """#[cfg(feature = "rdma")]
fn rdma_client_create(address: &str, port: u32, polling: bool) -> Option<RdmaClientBackend> {
"""

A5_NEW = '''#[cfg(feature = "rdma")]
fn rdma_server_create_ext(
    address: &str,
    port: u32,
    pool_ptr: *mut std::ffi::c_void,
    pool_size: usize,
    slot_size: usize,
) -> Option<RdmaServerBackend> {
    use easyrdma::*;
    use std::ffi::CString;

    if pool_ptr.is_null() || slot_size == 0 || pool_size < slot_size {
        eprintln!(
            "grpc_direct: RDMA external pool is invalid (ptr {:p}, size {}, slot {})",
            pool_ptr, pool_size, slot_size
        );
        return None;
    }
    let slots = pool_size / slot_size;

    let c_addr = CString::new(address).ok()?;
    let rx_port = port as u16;
    let tx_port = (port + 1) as u16;

    unsafe {
        let mut rx_listener: Session = INVALID_SESSION;
        let mut tx_listener: Session = INVALID_SESSION;

        if easyrdma_CreateListenerSession(c_addr.as_ptr(), rx_port, &mut rx_listener)
            != ERROR_SUCCESS
        {
            eprintln!(
                "grpc_direct: RDMA failed to create RX listener on port {}",
                rx_port
            );
            return None;
        }
        if easyrdma_CreateListenerSession(c_addr.as_ptr(), tx_port, &mut tx_listener)
            != ERROR_SUCCESS
        {
            eprintln!(
                "grpc_direct: RDMA failed to create TX listener on port {}",
                tx_port
            );
            easyrdma_CloseSession(rx_listener, 0);
            return None;
        }

        let mut rx_session: Session = INVALID_SESSION;
        let mut tx_session: Session = INVALID_SESSION;

        if easyrdma_Accept(
            rx_listener,
            DIRECTION_RECEIVE,
            TIMEOUT_INFINITE,
            &mut rx_session,
        ) != ERROR_SUCCESS
        {
            eprintln!("grpc_direct: RDMA accept on RX port {} failed", rx_port);
            easyrdma_CloseSession(rx_listener, 0);
            easyrdma_CloseSession(tx_listener, 0);
            return None;
        }
        if easyrdma_Accept(
            tx_listener,
            DIRECTION_SEND,
            TIMEOUT_INFINITE,
            &mut tx_session,
        ) != ERROR_SUCCESS
        {
            eprintln!("grpc_direct: RDMA accept on TX port {} failed", tx_port);
            easyrdma_AbortSession(rx_session);
            easyrdma_CloseSession(rx_session, 0);
            easyrdma_CloseSession(rx_listener, 0);
            easyrdma_CloseSession(tx_listener, 0);
            return None;
        }

        // No RX polling here. easyrdma rejects the property on an externally
        // buffered session, so RdmaLowLatency is not offered on this path
        // rather than being accepted and ignored.
        let mut cbdata = Vec::with_capacity(slots);
        for _ in 0..slots {
            cbdata.push(Box::new(BufferCompletionCallbackData::default()));
        }
        let mut pool = ExtRxPool {
            base: pool_ptr,
            pool_size,
            slot_size,
            slots,
            cbdata,
            shared: std::sync::Arc::new(ExtRxShared {
                ready: std::sync::Mutex::new(std::collections::VecDeque::with_capacity(slots)),
                cv: std::sync::Condvar::new(),
            }),
        };

        // The send session keeps driver-allocated buffers. Only the receive
        // side has a GPU consumer, and only the receive side is what phase 3 is
        // about; leaving TX alone keeps the response path identical to stock.
        if !ext_configure_rx(&mut pool, rx_session)
            || easyrdma_ConfigureBuffers(tx_session, RDMA_MAX_FRAME_SIZE, RDMA_MAX_CONCURRENT)
                != ERROR_SUCCESS
        {
            easyrdma_AbortSession(rx_session);
            easyrdma_CloseSession(rx_session, 0);
            easyrdma_AbortSession(tx_session);
            easyrdma_CloseSession(tx_session, 0);
            easyrdma_CloseSession(rx_listener, 0);
            easyrdma_CloseSession(tx_listener, 0);
            return None;
        }

        Some(RdmaServerBackend {
            rx_session,
            tx_session,
            rx_listener,
            tx_listener,
            rx_region: None,
            stream_region: None,
            polling: false,
            ext: Some(pool),
        })
    }
}

#[cfg(feature = "rdma")]
fn rdma_client_create(address: &str, port: u32, polling: bool) -> Option<RdmaClientBackend> {
'''


# ---------------------------------------------------------------------------
# 6. Guard the stock receive so an externally-buffered server cannot be read
#    through it. Failing loudly beats acquiring a region that the driver will
#    reject or, worse, a lifetime nobody owns.
# ---------------------------------------------------------------------------

A6_OLD = """        #[cfg(feature = "rdma")]
        ServerInner::Rdma(b) => {
            // Release any previously-held receive region before acquiring the next.
            if let Some(mut old_region) = b.rx_region.take() {
"""

A6_NEW = """        #[cfg(feature = "rdma")]
        ServerInner::Rdma(b) => {
            if b.ext.is_some() {
                eprintln!(
                    "grpc_direct: this server was created with \\
                     grpc_direct_server_create_ext; use \\
                     grpc_direct_server_receive_ext. The external path has no \\
                     release call, so slot lifetime cannot be inferred here."
                );
                return std::ptr::null_mut();
            }

            // Release any previously-held receive region before acquiring the next.
            if let Some(mut old_region) = b.rx_region.take() {
"""


# ---------------------------------------------------------------------------
# 7. The two new exported entry points, after grpc_direct_server_create.
# ---------------------------------------------------------------------------

A7_OLD = """    Box::into_raw(Box::new(Server { inner }))
}

/// Try to receive a request.
"""

A7_NEW = '''    Box::into_raw(Box::new(Server { inner }))
}

/// Create an RDMA server that receives directly into a caller-owned pool.
///
/// `pool_ptr` must stay mapped and untouched by the caller for the lifetime of
/// the server. On the DGX it is a cudaHostAlloc allocation, which on GB10 is
/// coherent, so the host address the NIC writes to and the device address a
/// kernel reads from are the same number.
///
/// The pool is divided into `pool_size / slot_size` slots. Each is armed at
/// create time. After that, a slot is only re-armed when the caller calls
/// `grpc_direct_server_slot_requeue`, which is deliberate: the re-queue is the
/// flow-control credit, so holding it back is how the caller keeps the NIC from
/// overwriting a payload that a GPU kernel is still reading.
///
/// `transport` must be `Rdma`. `RdmaLowLatency` is rejected because easyrdma
/// will not enable RX polling on an externally buffered session.
///
/// Returns NULL on failure.
#[no_mangle]
pub unsafe extern "C" fn grpc_direct_server_create_ext(
    service_name: *const c_char,
    transport: Transport,
    address: *const c_char,
    port: u32,
    pool_ptr: *mut std::ffi::c_void,
    pool_size: usize,
    slot_size: usize,
) -> *mut Server {
    let _ = service_name;

    #[cfg(feature = "rdma")]
    {
        match transport {
            Transport::Rdma => {}
            Transport::RdmaLowLatency => {
                eprintln!(
                    "grpc_direct: RdmaLowLatency cannot use external buffers; \\
                     easyrdma rejects RX polling on an externally buffered session"
                );
                return std::ptr::null_mut();
            }
            _ => {
                eprintln!(
                    "grpc_direct: grpc_direct_server_create_ext is RDMA-only; \\
                     use grpc_direct_server_create for other transports"
                );
                return std::ptr::null_mut();
            }
        }

        let addr_str = if address.is_null() {
            "0.0.0.0".to_string()
        } else {
            CStr::from_ptr(address).to_string_lossy().into_owned()
        };

        match rdma_server_create_ext(&addr_str, port, pool_ptr, pool_size, slot_size) {
            Some(b) => {
                eprintln!(
                    "grpc_direct {}: RDMA external-buffer server on {}:{} \\
                     (pool {:p}, {} bytes, {} slots of {})",
                    version_str(),
                    addr_str,
                    port,
                    pool_ptr,
                    pool_size,
                    pool_size / slot_size,
                    slot_size
                );
                Box::into_raw(Box::new(Server {
                    inner: ServerInner::Rdma(b),
                }))
            }
            None => {
                eprintln!(
                    "grpc_direct: failed to create RDMA external-buffer server on {}:{}",
                    addr_str, port
                );
                std::ptr::null_mut()
            }
        }
    }

    #[cfg(not(feature = "rdma"))]
    {
        let _ = (transport, address, port, pool_ptr, pool_size, slot_size);
        eprintln!(
            "grpc_direct: external buffers require the 'rdma' feature \\
             (recompile with --features rdma)"
        );
        std::ptr::null_mut()
    }
}

/// Receive from an externally buffered server.
///
/// On success `*request_ptr` points inside the caller's pool and `*slot_out`
/// is the slot index to hand back to `grpc_direct_server_slot_requeue`. The
/// pointer stays valid until that call, and not one instruction longer: the
/// re-queue is what allows the NIC to write there again.
///
/// Returns NULL on failure, including on peer disconnect, which arrives here as
/// a non-zero completion status rather than as a return code because the
/// external path has no blocking acquire to return it from.
#[no_mangle]
pub unsafe extern "C" fn grpc_direct_server_receive_ext(
    handle: *mut Server,
    request_ptr: *mut *const u8,
    request_size: *mut usize,
    slot_out: *mut usize,
) -> *mut ActiveRequest {
    #[cfg(feature = "rdma")]
    {
        let server = &mut *handle;
        let (tx_session, pool) = match &mut server.inner {
            ServerInner::Rdma(b) => {
                let tx = b.tx_session;
                match b.ext.as_mut() {
                    Some(p) => (tx, p),
                    None => {
                        eprintln!(
                            "grpc_direct: receive_ext needs a server built by \\
                             grpc_direct_server_create_ext"
                        );
                        return std::ptr::null_mut();
                    }
                }
            }
            _ => {
                eprintln!("grpc_direct: receive_ext is RDMA-only");
                return std::ptr::null_mut();
            }
        };

        let comp = {
            let mut q = match pool.shared.ready.lock() {
                Ok(g) => g,
                Err(p) => p.into_inner(),
            };
            loop {
                if let Some(c) = q.pop_front() {
                    break c;
                }
                q = match pool.shared.cv.wait(q) {
                    Ok(g) => g,
                    Err(p) => p.into_inner(),
                };
            }
        };

        if comp.status != easyrdma::ERROR_SUCCESS {
            eprintln!(
                "grpc_direct: RDMA external receive on slot {} completed with {}",
                comp.slot, comp.status
            );
            return std::ptr::null_mut();
        }

        let data_ptr = (pool.base as *const u8).add(comp.slot * pool.slot_size);
        let data_len = comp.bytes;

        *request_ptr = data_ptr;
        *request_size = data_len;
        if !slot_out.is_null() {
            *slot_out = comp.slot;
        }

        Box::into_raw(Box::new(ActiveRequest {
            inner: ActiveRequestInner::Rdma {
                data_ptr,
                data_len,
                tx_session,
            },
            loan: LoanState::None,
            rdma_reserved: None,
        }))
    }

    #[cfg(not(feature = "rdma"))]
    {
        let _ = (handle, request_ptr, request_size, slot_out);
        eprintln!("grpc_direct: receive_ext requires the 'rdma' feature");
        std::ptr::null_mut()
    }
}

/// Hand a slot back to the NIC.
///
/// This is the whole lifetime contract. Until this is called the payload in the
/// slot is the caller's; after it, the NIC may overwrite it at any moment. A
/// caller with a GPU consumer must not call this until the consuming work has
/// actually completed, which for an asynchronous launch means after the CUDA
/// event recorded behind that work has been synchronised, not after the launch
/// returns.
///
/// Returns 0 on success, or the easyrdma status, or -1 if the handle or slot is
/// not valid.
#[no_mangle]
pub unsafe extern "C" fn grpc_direct_server_slot_requeue(handle: *mut Server, slot: usize) -> i32 {
    #[cfg(feature = "rdma")]
    {
        if handle.is_null() {
            return -1;
        }
        let server = &mut *handle;
        match &mut server.inner {
            ServerInner::Rdma(b) => {
                let rx = b.rx_session;
                let pool = match b.ext.as_mut() {
                    Some(p) => p,
                    None => return -1,
                };
                if slot >= pool.slots {
                    return -1;
                }
                let rc = ext_queue_slot(pool, rx, slot);
                if rc == easyrdma::ERROR_SUCCESS {
                    0
                } else {
                    rc
                }
            }
            _ => -1,
        }
    }

    #[cfg(not(feature = "rdma"))]
    {
        let _ = (handle, slot);
        -1
    }
}

/// Try to receive a request.
'''


EDITS = [
    ("rdma constants", A1_OLD, A1_NEW),
    ("backend ext field", A2_OLD, A2_NEW),
    ("re-accept buffer config", A3_OLD, A3_NEW),
    ("stock backend construction", A4_OLD, A4_NEW),
    ("rdma_server_create_ext", A5_OLD, A5_NEW),
    ("stock receive guard", A6_OLD, A6_NEW),
    ("exported entry points", A7_OLD, A7_NEW),
]


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()

    if MARKER in src:
        print("SKIP: external-buffer server path already present in {}".format(path))
        return 0

    for name, old, new in EDITS:
        n = src.count(old)
        if n != 1:
            print("FAIL: anchor '{}' appears {} times, expected 1".format(name, n))
            return 1
        src = src.replace(old, new, 1)
        print("  ok: {}".format(name))

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)

    print("PATCHED {} ({} lines)".format(path, src.count("\n") + 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
