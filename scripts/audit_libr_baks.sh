#!/usr/bin/env bash
# What do the four lib.rs.bak snapshots contain that the current lib.rs does not?
#
# The PXI's grpc-direct has no .git, so these four files are the only record of
# how src/lib.rs got to its current state. The question that matters is not what
# each one added, but whether anything was tried and then REMOVED, since a
# removal is the only thing that would not show up in a plain upstream diff.

set -u
cd /home/admin/grpc-direct/src || exit 1

echo "=== sizes and timestamps ==="
ls -la --time-style=long-iso lib.rs lib.rs.bak lib.rs.bak2 lib.rs.bak3 lib.rs.bak4

prev=""
for f in lib.rs.bak lib.rs.bak2 lib.rs.bak3 lib.rs.bak4 lib.rs; do
  if [ -n "$prev" ]; then
    echo
    echo "=== $prev -> $f ==="
    diff -u "$prev" "$f" | grep -c '^+[^+]' | sed 's/^/  lines added:   /'
    diff -u "$prev" "$f" | grep -c '^-[^-]' | sed 's/^/  lines removed: /'
    echo "  --- fn/const/struct items REMOVED at this step ---"
    diff -u "$prev" "$f" \
      | grep '^-' \
      | grep -E 'fn |const |struct |static ' \
      | sed 's/^/    /' \
      | head -40
  fi
  prev="$f"
done

echo
echo "=== identifiers present in any .bak but absent from the current lib.rs ==="
# Pull every function name defined in each snapshot, and report any that
# do not survive into the current file.
cur=$(grep -oE '\bfn [a-z_0-9]+' lib.rs | sort -u)
for f in lib.rs.bak lib.rs.bak2 lib.rs.bak3 lib.rs.bak4; do
  echo "  $f:"
  comm -23 <(grep -oE '\bfn [a-z_0-9]+' "$f" | sort -u) <(echo "$cur") | sed 's/^/    DROPPED: /'
done

echo
echo "=== does any snapshot mention the external-buffer API? ==="
grep -nE 'ConfigureExternalBuffer|QueueExternalBufferRegion|ReleaseUserBufferRegionToIdle|UserBuffers|DeferWhileUserBuffers' \
  lib.rs lib.rs.bak lib.rs.bak2 lib.rs.bak3 lib.rs.bak4 || echo "  no mention in any snapshot"
