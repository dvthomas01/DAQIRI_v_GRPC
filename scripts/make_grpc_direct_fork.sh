#!/usr/bin/env bash
# Turn the Spark's grpc-direct working tree into a real branch with real
# history, then export it as a bundle.
#
# Two commits on purpose. The first is the state every gRPC number in the
# DAQIRI repo was measured against, so it has to be separable from anything we
# do afterwards. The second is our Phase 3 work.
#
# Nothing is pushed from this box. The bundle is carried off and pushed from a
# machine whose credentials were never exposed.
set -eu
export PATH="$HOME/.cargo/bin:/usr/bin:/bin"
cd "$HOME/grpc-direct"

BRANCH=daqiri-extbuf
BASE=2d404a5df176d885fbdddce9192c09f7f370a06a

if [ "$(git rev-parse HEAD)" != "$BASE" ]; then
  echo "FAIL: HEAD is not the expected upstream base"; exit 1
fi

git config user.name  "DAQIRI GPU benchmark"
git config user.email "daqiri-bench@local"

# Keep scratch out of the history. These are hand-edit snapshots, not source.
if ! grep -q '^\*\.bak' .gitignore; then
  {
    echo ""
    echo "# Hand-edit snapshots taken while developing the DAQIRI fork."
    echo "*.bak"
    echo "*.bak[0-9]"
    echo "*.bak_*"
    echo "python/grpc_direct.egg-info/"
  } >> .gitignore
fi

git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"

# ---- commit 1: the measured state -------------------------------------------
cp src/lib.rs /tmp/lib_rs_with_ffi.rs
cp src/lib.rs.bak5 src/lib.rs        # bak5 = pre-FFI, md5 b61b26dae6ec...

git add -A
echo "### staged for commit 1 ###"
git status --porcelain

git commit -q -F - <<'MSG'
DAQIRI fork of ni/grpc-direct: the state the benchmarks were measured against

Recovered from an uncommitted working tree on the DGX Spark. Every gRPC number
in the DAQIRI_v_GRPC repo was produced against exactly this tree, so it is
recorded as one commit before any further work, rather than being mixed in with
it.

src/lib.rs, +529/-31 in five coherent changes, adds the easyrdma RDMA transport
behind --features rdma.

cpp/client_interceptor.cc, +16/-5, fixes server-streaming end-of-stream
handling: adds a firstRecv_ flag so the continuation ack is not sent before the
first receive, and calls FailHijackedRecvMessage() on the zero-length-response
EOS paths so Read() actually terminates instead of hanging. Audited against the
DAQIRI benchmark: that benchmark is client-streaming, the behavioural branch is
guarded by callType == SERVER_STREAMING, and the unguarded additions require a
zero-byte response which cannot occur there. So this changes nothing for those
numbers, but it is in the binary and the record should say so.

plugin/cmd/protoc-gen-grpc-direct/gen_cpp.go, 2 lines, _actual -> _response in
the generated Direct<Msg> move constructor and move assignment. Upstream emits
a reference to a member that does not exist, so upstream's generated C++ does
not compile.

.cargo/config.toml pins the cross linker for x86_64-unknown-linux-gnu.

The python/ restructure and the examples/ additions came along with the tree.

Base: upstream 2d404a5df176d885fbdddce9192c09f7f370a06a
MSG

echo "commit 1: $(git rev-parse --short HEAD)"

# ---- commit 2: phase 3 step 3 -----------------------------------------------
cp /tmp/lib_rs_with_ffi.rs src/lib.rs
git add -A
echo "### staged for commit 2 ###"
git status --porcelain

git commit -q -F - <<'MSG'
phase 3 step 3: bind the easyrdma external-buffer entry points

Two functions, not three: easyrdma_ConfigureExternalBuffer and
easyrdma_QueueExternalBufferRegion, plus easyrdma_BufferCompletionCallbackData
and its function-pointer typedef.

ReleaseUserBufferRegionToIdle is deliberately absent. ConfigureExternalBuffer
never sets autoQueueRx the way ConfigureBuffers does, so the queue call is both
the re-arm and the flow-control credit, and the UserBuffers property reads 0
immediately after a completion callback with no release call. Measured, not
assumed.

Also bound: PROPERTY_USER_BUFFERS (0x102);
CLOSE_DEFER_WHILE_USER_BUFFERS_OUTSTANDING (0x01), which is mandatory because
closing a session with a queued external region corrupts the heap; and the
InvalidOperation / AlreadyConfigured / OperationNotSupported codes.

Option<BufferCompletionCallback> is null-pointer-optimised, so the struct
matches the C layout exactly and a None callback is a null pointer.

cargo build --release --features rdma exits 0. The new warnings are dead-code
and stay until the call sites are wired.
MSG

echo "commit 2: $(git rev-parse --short HEAD)"

echo
echo "###### history ######"
git log --oneline "$BASE..$BRANCH"

echo
echo "###### tree must be clean ######"
git status --porcelain || true

echo
echo "###### no secret in anything committed ######"
if git grep -I -n 'ghp_' "$BRANCH" -- . ; then
  echo "FAIL: token found in committed content"; exit 1
else
  echo "clean: no ghp_ in the branch"
fi

echo
echo "###### bundle ######"
rm -f /tmp/grpc-direct.bundle
git bundle create /tmp/grpc-direct.bundle main "$BRANCH"
git bundle verify /tmp/grpc-direct.bundle
ls -l /tmp/grpc-direct.bundle
