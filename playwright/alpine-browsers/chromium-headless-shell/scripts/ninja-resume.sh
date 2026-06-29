#!/usr/bin/env bash
# Resumable ninja round invoked from Dockerfile.
#
# Usage:  ninja-resume.sh <work_dir> <round_name> [final]
#
#   work_dir    — same /work path that apply-and-build.sh used (with
#                  versions.env, derived.env, aports/, chromium-src/).
#   round_name  — label printed in logs ("round-1", "round-2", "final").
#   final       — when set to "final", ninja runs without `timeout … || true`;
#                  any non-zero ninja rc fails the layer (used by the last
#                  resume round to fail the build if obj/ is still incomplete).
#
# Why this script: chromium 148 cold build > GHA hosted-runner 6h cap on a
# 4-vCPU runner. The Dockerfile splits ninja into multiple resumable RUNs.
# Each round commits its partial obj/ as a Docker layer; cache-to=registry
# persists across CI iters; the next iter cache-from restores prior rounds
# and resumes from where the obj/ tree left off. After enough rounds the
# final invocation closes out the build.

set -euo pipefail

WORK="${1:?usage: ninja-resume.sh <work_dir> <round_name> [final]}"
LABEL="${2:?usage: ninja-resume.sh <work_dir> <round_name> [final]}"
FINAL="${3:-}"

set -a; . "$WORK/versions.env"; . "$WORK/derived.env"; set +a

# sccache GHA backend pickup
export SCCACHE_GHA_ENABLED=true
ACTIONS_RUNTIME_TOKEN="$(cat /run/secrets/actions_runtime_token 2>/dev/null || echo)"
ACTIONS_RESULTS_URL="$(cat /run/secrets/actions_results_url 2>/dev/null || echo)"
if [[ -z "$ACTIONS_RUNTIME_TOKEN" || -z "$ACTIONS_RESULTS_URL" ]]; then
  echo "WARN: GHA cache env not provided — sccache will use local mount only" >&2
  unset SCCACHE_GHA_ENABLED
else
  export ACTIONS_RUNTIME_TOKEN ACTIONS_RESULTS_URL
  echo "  sccache GHA backend enabled (token len=${#ACTIONS_RUNTIME_TOKEN})"
fi

# Toolchain env — must match what gn gen recorded.
LLVMVER=$(awk -F= '$1=="_llvmver"{gsub(/[^0-9]/,"",$2);print $2;exit}' "$WORK/aports/APKBUILD")
CLANG_BASE="/usr/lib/llvm${LLVMVER:-22}"
export AR="$CLANG_BASE/bin/llvm-ar"
export NM="$CLANG_BASE/bin/llvm-nm"
export CC="$CLANG_BASE/bin/clang"
export CXX="$CLANG_BASE/bin/clang++"
export RUSTC_BOOTSTRAP=1

SRC="$WORK/chromium-src/chromium-${CHS_VER}"
OUT="out/headless"
cd "$SRC"

# Pre-round status: how many .o files already on disk (resumed work).
PRE_OBJ_COUNT=$(find "$OUT" -name '*.o' 2>/dev/null | wc -l)
echo "===== ninja $LABEL — starting with $PRE_OBJ_COUNT .o files on disk ====="

# Final round vs resumable round
if [[ "$FINAL" == "final" ]]; then
  ninja -C "$OUT" -j "$(nproc)" headless_shell
  rc=$?
else
  # 5h hard cap (300m × 60 = 18000s); ninja's own SIGTERM handler drains
  # in-flight jobs, then exits 124. `|| true` lets the layer commit with
  # whatever obj/ files were written before the cap.
  timeout 18000 ninja -C "$OUT" -j "$(nproc)" headless_shell || true
  rc=0
fi

POST_OBJ_COUNT=$(find "$OUT" -name '*.o' 2>/dev/null | wc -l)
DELTA=$((POST_OBJ_COUNT - PRE_OBJ_COUNT))
echo "===== ninja $LABEL — ended with $POST_OBJ_COUNT .o files (+$DELTA this round) ====="

# sccache stats (best-effort — log even if unavailable)
sccache --show-stats 2>&1 | sed 's/^/  sccache: /' || true

exit $rc
