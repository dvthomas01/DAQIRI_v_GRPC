#!/usr/bin/env bash
# Inspect the Spark's grpc-direct working tree before turning it into a fork.
set -u
cd "$HOME/grpc-direct" || exit 1
export PATH="$HOME/.cargo/bin:/usr/bin:/bin"

echo "###### HEAD ######"
git rev-parse HEAD
git log -1 --format='%H %an %ad %s' --date=iso

echo
echo "###### branches ######"
git branch -vv

echo
echo "###### status (porcelain) ######"
git status --porcelain

echo
echo "###### .gitignore ######"
cat .gitignore 2>/dev/null || echo "(none)"

echo
echo "###### diffstat of tracked modifications ######"
git diff --stat
