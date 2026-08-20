#!/usr/bin/env bash
# Hash a grpc-direct working copy the same way the PXI copy was hashed, so the
# Spark's copy can be classified against upstream and against the PXI.
#
# Same exclusions as the PXI run: no target/, no .git, no .github.
set -u
D="${1:-$HOME/grpc-direct}"
cd "$D" || { echo "no $D"; exit 1; }

echo "### dir: $D"
echo "### has .git: $([ -d .git ] && echo yes || echo no)"
echo "### bak files:"
ls -la src/*.bak* 2>/dev/null || echo "  (none)"
echo "### newest source timestamps:"
find . -path ./target -prune -o -name '*.rs' -print0 2>/dev/null \
  | xargs -0 ls -l --time-style=+%Y-%m-%dT%H:%M 2>/dev/null | sort -k6 | tail -5
echo "### HASHES"
find . -type f \
  -not -path './target/*' \
  -not -path './.git/*' \
  -not -path './.github/*' \
  -print0 | sort -z | xargs -0 md5sum
