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

# derived.env exposes CHROMIUM_HEADLESS_SHELL_{REVISION,VERSION}; apply-and-build.sh
# renames them to CHS_REV/CHS_VER internally. Mirror that rename here so the
# `chromium-${CHS_VER}` source path resolves.
CHS_REV="${CHROMIUM_HEADLESS_SHELL_REVISION:?derived.env missing CHROMIUM_HEADLESS_SHELL_REVISION}"
CHS_VER="${CHROMIUM_HEADLESS_SHELL_VERSION:?derived.env missing CHROMIUM_HEADLESS_SHELL_VERSION}"

# sccache GHA backend pickup.
# ACTIONS_CACHE_SERVICE_V2=1 flips opendal's ghac backend to v2 Twirp API
# (endpoint `/twirp/github.actions.results.api.v1.CacheService/*`). Without
# it opendal targets the deprecated v1 path `/_apis/artifactcache/cache`
# which GitHub returns 404 for — every write fails with the misleading
# "Cannot write to read-only storage" opendal error. See project_sccache_ghac_readonly_v18.
export SCCACHE_GHA_ENABLED=true
export ACTIONS_CACHE_SERVICE_V2=1
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

# VARIANT (headless|headed) selects out dir + ninja target + binary name.
. "$WORK/chromium-headless-shell/scripts/variant-config.sh"

SRC="$WORK/chromium-src/chromium-${CHS_VER}"
OUT="$VARIANT_OUT_DIR"
cd "$SRC"

# Pre-round status: how many .o files already on disk (resumed work).
PRE_OBJ_COUNT=$(find "$OUT" -name '*.o' 2>/dev/null | wc -l)
echo "===== ninja $LABEL — starting with $PRE_OBJ_COUNT .o files on disk ====="

# Final round vs resumable round
if [[ "$FINAL" == "final" ]]; then
  ninja -C "$OUT" -j "$(nproc)" $VARIANT_TARGET
  rc=$?
else
  # 5h hard cap (300m × 60 = 18000s); ninja's own SIGTERM handler drains
  # in-flight jobs, then exits 124. `|| true` lets the layer commit with
  # whatever obj/ files were written before the cap.
  timeout 18000 ninja -C "$OUT" -j "$(nproc)" $VARIANT_TARGET || true
  rc=0
fi

POST_OBJ_COUNT=$(find "$OUT" -name '*.o' 2>/dev/null | wc -l)
DELTA=$((POST_OBJ_COUNT - PRE_OBJ_COUNT))
echo "===== ninja $LABEL — ended with $POST_OBJ_COUNT .o files (+$DELTA this round) ====="

# sccache stats (best-effort — log even if unavailable)
sccache --show-stats 2>&1 | sed 's/^/  sccache: /' || true

# On final round with rc=0, do the dist copy that apply-and-build.sh normally
# does post-ninja (it exited early via PW_CHROMIUM_SKIP_NINJA=1 in setup).
# Mirrors apply-and-build.sh section 9 — see the file-list rationale there.
# v28 (28830225815) diagnostic (getBoundingClientRect on <div style="1px;1px">
# returned {width:0,height:17,display:inline}) proved the UA stylesheet was
# missing because headless_lib_data.pak (a FILE, not the previously-checked
# directory) was never copied, and PW's official ubuntu image ships more paks
# than the old list matched.
if [[ "$FINAL" == "final" && $rc -eq 0 ]]; then
  BIN="$OUT/$VARIANT_BIN"
  if [[ ! -x "$BIN" ]]; then
    echo "ERROR: expected $BIN after final ninja" >&2
    ls -la "$OUT" | head -20
    exit 6
  fi
  DIST="$WORK/chromium-dist"
  mkdir -p "$DIST"
  cp -a "$BIN" "$DIST/"
  # Shared runtime data (both variants): ICU, V8 snapshots, SwiftShader.
  for f in icudtl.dat snapshot_blob.bin v8_context_snapshot.bin \
           vk_swiftshader_icd.json; do
    [[ -f "$OUT/$f" ]] && cp -a "$OUT/$f" "$DIST/"
  done
  if [[ "$VARIANT" == "headed" ]]; then
    # Full chrome: the crashpad handler + the desktop .pak set + UI resources.
    # chrome refuses to start without chrome_100_percent.pak + resources.pak.
    for f in chrome_crashpad_handler product_logo_48.png \
             chrome_100_percent.pak chrome_200_percent.pak resources.pak; do
      [[ -f "$OUT/$f" ]] && cp -a "$OUT/$f" "$DIST/"
    done
    for d in locales resources MEIPreload; do
      [[ -d "$OUT/$d" ]] && cp -a "$OUT/$d" "$DIST/"
    done
  else
    # Headless-shell paks (no chrome UI resources).
    for f in headless_command_resources.pak headless_lib_data.pak headless_lib_strings.pak; do
      [[ -f "$OUT/$f" ]] && cp -a "$OUT/$f" "$DIST/"
    done
    for d in locales hyphen-data; do
      [[ -d "$OUT/$d" ]] && cp -a "$OUT/$d" "$DIST/"
    done
  fi
  find "$OUT" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) -exec cp -a {} "$DIST/" \;
  echo "===== DIST staged at $DIST ($VARIANT) ====="
  ls -lh "$DIST" | head -30
fi

exit $rc
