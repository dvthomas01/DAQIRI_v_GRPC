#!/usr/bin/env bash
# The Spark's grpc-direct has a .git, which the PXI's does not. That is the
# history the PXI audit had to reconstruct from hashes. Read it.
set -u
cd "$HOME/grpc-direct" || exit 1

echo "###### remotes ######"
git remote -v

echo
echo "###### branches ######"
git branch -avv

echo
echo "###### log ######"
git log --oneline --decorate --all -30

echo
echo "###### HEAD ######"
git rev-parse HEAD
git log -1 --format='%H%n%an <%ae>%n%ad%n%s'

echo
echo "###### working tree status ######"
git status --short

echo
echo "###### is lib.rs committed or dirty? ######"
git diff --stat -- src/lib.rs
echo "--- staged ---"
git diff --cached --stat -- src/lib.rs

echo
echo "###### does upstream 2d404a5 exist in this history? ######"
git cat-file -t 2d404a5 2>&1 || echo "  not present"
git merge-base --is-ancestor 2d404a5 HEAD 2>/dev/null && echo "  2d404a5 IS an ancestor of HEAD" || echo "  2d404a5 is NOT an ancestor of HEAD (or not present)"

echo
echo "###### md5 of the working lib.rs and each bak ######"
md5sum src/lib.rs src/lib.rs.bak* 2>/dev/null

echo
echo "###### is the Spark tree the same as the PXI tree? spot-check lib.rs ######"
wc -l src/lib.rs
