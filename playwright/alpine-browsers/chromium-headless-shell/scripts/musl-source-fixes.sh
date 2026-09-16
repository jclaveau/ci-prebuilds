#!/usr/bin/env bash
# Source fixes the musl build needs that neither aports nor copium carry.
# Idempotent: apply-and-build.sh runs it once at setup, ninja-resume.sh runs
# it again before every ninja so a chain resumed from an older round image
# (resume_from) still picks up a fix added after that image was baked.
#
# Usage: musl-source-fixes.sh <chromium-src-dir>
set -euo pipefail
cd "${1:?chromium source dir}"

# sqlite calls ioctl through its aSyscall[] table cast to
# int(*)(int, unsigned long, ...) — glibc's prototype. musl (like bionic)
# declares int ioctl(int, int, ...), so under -fsanitize=cfi-icall the call in
# setDeviceCharacteristics is a provable type mismatch: clang folds the whole
# sectorSize==0 branch into a ud1 trap and every sql::Database::Open SIGILLs
# (run 34387189058, 358/358 launches). sqlite already carries the bionic
# signature under __ANDROID__; take that branch on every non-glibc libc.
echo "===== musl source fixes: sqlite ioctl cast ====="
for f in third_party/sqlite/src/amalgamation*/sqlite3.c; do
  [[ -f "$f" ]] || continue
  if grep -q '^# if defined(__ANDROID__) || !defined(__GLIBC__)$' "$f"; then
    echo "  $f: already patched"
    continue
  fi
  sed -i '/^#if defined(__linux__) && defined(SQLITE_ENABLE_BATCH_ATOMIC_WRITE)$/,/^#endif/ s/^# ifdef __ANDROID__$/# if defined(__ANDROID__) || !defined(__GLIBC__)/' "$f"
  n=$(grep -c '^# if defined(__ANDROID__) || !defined(__GLIBC__)$' "$f")
  [[ "$n" == 1 ]] || { echo "ERROR: sqlite ioctl fix landed $n times in $f, expected 1" >&2; exit 9; }
  echo "  $f: patched"
done
