#!/usr/bin/env bash
# Rebuild the fork branch from the reflog, dropping the built .so.
#
# The previous attempt used `git checkout -f main`, which discarded the
# uncommitted working-tree edits. They survived only because they had already
# been committed to ab25423, which is still reachable through the reflog. This
# script recovers from that commit rather than from the working tree.
set -eu
export PATH="$HOME/.cargo/bin:/usr/bin:/bin"
cd "$HOME/grpc-direct"

BRANCH=daqiri-extbuf
BASE=2d404a5df176d885fbdddce9192c09f7f370a06a
FULL=ab2542355fc408cd5d4608dde78cccf9533d7018   # tree with everything, incl. .so

# 1. Restore the complete tree from the reflog commit.
git checkout -B "$BRANCH" "$FULL" -q
git checkout "$FULL" -- . -q 2>/dev/null || true

echo "###### recovered tree: sanity checks ######"
echo -n "interceptor firstRecv_ occurrences: "; grep -c 'firstRecv_' cpp/client_interceptor.cc
echo -n "gen_cpp.go _response occurrences:   "; grep -c '_response' plugin/cmd/protoc-gen-grpc-direct/gen_cpp.go
echo -n "lib.rs ConfigureExternalBuffer:     "; grep -c 'easyrdma_ConfigureExternalBuffer' src/lib.rs
echo -n ".cargo/config.toml present:         "; test -f .cargo/config.toml && echo yes || echo NO

# 2. Keep both lib.rs states.
cp src/lib.rs /tmp/lib_rs_with_ffi.rs
git show "$FULL"~1:src/lib.rs > /tmp/lib_rs_measured.rs

# 3. Collapse to the base, keeping everything staged.
git reset --soft "$BASE"

# 4. Drop the build artifact and ignore it.
git rm -r --cached --quiet python/grpc_direct/lib 2>/dev/null || true
grep -q 'python/grpc_direct/lib/' .gitignore || echo "python/grpc_direct/lib/" >> .gitignore
git add .gitignore

# 5. Commit 1: the measured state.
cp /tmp/lib_rs_measured.rs src/lib.rs
git add src/lib.rs
echo
echo "###### staged for commit 1 ######"
git status --porcelain
git commit -q -F /tmp/fork_msg1.txt
echo "commit 1: $(git rev-parse --short HEAD)"

# 6. Commit 2: the FFI bindings.
cp /tmp/lib_rs_with_ffi.rs src/lib.rs
git add src/lib.rs
echo
echo "###### staged for commit 2 ######"
git status --porcelain
git commit -q -F /tmp/fork_msg2.txt
echo "commit 2: $(git rev-parse --short HEAD)"

echo
echo "###### history ######"
git log --oneline --stat "$BASE..$BRANCH" | head -40

echo
echo "###### no build artifacts, no scratch ######"
if git ls-tree -r --name-only "$BRANCH" | grep -E '\.so$|\.bak|egg-info'; then
  echo "FAIL: artifact present"; exit 1
else
  echo "clean"
fi

echo
echo "###### no secret ######"
if git grep -I -q 'ghp_' "$BRANCH" -- .; then echo "FAIL: token"; exit 1; else echo "clean"; fi

echo
echo "###### bundle ######"
rm -f /tmp/grpc-direct.bundle
git bundle create /tmp/grpc-direct.bundle main "$BRANCH"
git bundle verify /tmp/grpc-direct.bundle
ls -lh /tmp/grpc-direct.bundle
