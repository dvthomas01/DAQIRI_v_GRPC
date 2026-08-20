#!/usr/bin/env bash
# Redo the fork branch without the built libgrpc_direct.so that slipped into
# commit 1. A 22 MB binary is a build artifact, not source, and it dominated
# the bundle.
set -eu
export PATH="$HOME/.cargo/bin:/usr/bin:/bin"
cd "$HOME/grpc-direct"

BRANCH=daqiri-extbuf
BASE=2d404a5df176d885fbdddce9192c09f7f370a06a

# Stash the two lib.rs states before rewinding.
git show "$BRANCH":src/lib.rs        > /tmp/lib_rs_with_ffi.rs
git show "$BRANCH"~1:src/lib.rs      > /tmp/lib_rs_measured.rs

if ! grep -q 'python/grpc_direct/lib/' .gitignore; then
  {
    echo "python/grpc_direct/lib/"
  } >> .gitignore
fi
cp .gitignore /tmp/gitignore.keep

git checkout -f main -q
git branch -D "$BRANCH" -q
git checkout -b "$BRANCH" -q
cp /tmp/gitignore.keep .gitignore
git rm -r --cached python/grpc_direct/lib >/dev/null 2>&1 || true

cp /tmp/lib_rs_measured.rs src/lib.rs
git add -A
echo "### staged for commit 1 ###"
git status --porcelain
git commit -q -F /tmp/fork_msg1.txt
echo "commit 1: $(git rev-parse --short HEAD)"

cp /tmp/lib_rs_with_ffi.rs src/lib.rs
git add -A
echo "### staged for commit 2 ###"
git status --porcelain
git commit -q -F /tmp/fork_msg2.txt
echo "commit 2: $(git rev-parse --short HEAD)"

echo
echo "###### history ######"
git log --oneline "$BASE..$BRANCH"

echo
echo "###### no build artifacts committed ######"
git ls-tree -r --name-only "$BRANCH" | grep -E '\.so$|\.bak|egg-info' && echo "FAIL: artifact present" || echo "clean"

echo
echo "###### no secret ######"
git grep -I -n 'ghp_' "$BRANCH" -- . && { echo "FAIL: token"; exit 1; } || echo "clean: no ghp_"

echo
echo "###### bundle ######"
rm -f /tmp/grpc-direct.bundle
git bundle create /tmp/grpc-direct.bundle main "$BRANCH"
git bundle verify /tmp/grpc-direct.bundle
ls -lh /tmp/grpc-direct.bundle
