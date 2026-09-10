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

# TEMP warm-fix (headed printing). The chr-build-r14 obj/ image was gen'd with
# printing OFF (a stale lean-cut in args.gn.headed.overlay); the chrome target
# actually needs print-preview, so its final link fails. Rather than re-gen the
# whole 5-day chain, re-flip the flags on the baked args.gn (later gn
# assignments win) and `gn gen` so the warm finalize compiles ONLY the
# print-preview delta on top of r14's warm obj/. The overlay is now correct, so
# a clean rebuild needs none of this. TODO(headed-printing-cold-rebuild): drop
# this block + the Dockerfile.finalize ARG once path A (clean rebuild from the
# fixed overlay) has produced the artifact.
if [ "${PATCH_HEADED_PRINTING:-0}" = "1" ]; then
  echo "===== PATCH_HEADED_PRINTING=1 — re-enabling print-preview on baked args.gn ====="
  # sed-REPLACE the baked false lines (gn forbids reassigning an arg already set
  # in args.gn, so appending a second `= true` is a no-op / error — must edit
  # in place). use_cups stays false.
  sed -i -E \
    -e 's/^enable_basic_printing = false/enable_basic_printing = true/' \
    -e 's/^enable_print_preview = false/enable_print_preview = true/' \
    "$OUT/args.gn"
  grep -E '^(enable_basic_printing|enable_print_preview|use_cups) ' "$OUT/args.gn"
  gn gen "$OUT"
fi

# Pre-round status: how many .o files already on disk (resumed work).
PRE_OBJ_COUNT=$(find "$OUT" -name '*.o' 2>/dev/null | wc -l)
echo "===== ninja $LABEL — starting with $PRE_OBJ_COUNT .o files on disk ====="

# Report from a trap rather than after the ninja call below. The 18000s
# `timeout` ends this script along with ninja, so on a full-length round every
# line after it was skipped and the round reported nothing at all: run
# 32745725864's r1 went straight from "received signal: Terminated" to the
# layer export. Only rounds that died EARLY ever printed their counters, which
# is why the one sccache reading we have (1.33% hits, 210 write errors) comes
# from run 32739278406's 979s round and no 5h round has ever reported.
ROUND_REPORTED=0
report_round() {
  if [[ "$ROUND_REPORTED" == 1 ]]; then
    return 0
  fi
  ROUND_REPORTED=1
  kill "$SCCACHE_TICKER_PID" 2>/dev/null || true

  POST_OBJ_COUNT=$(find "$OUT" -name '*.o' 2>/dev/null | wc -l)
  DELTA=$((POST_OBJ_COUNT - PRE_OBJ_COUNT))
  echo "===== ninja $LABEL — ended with $POST_OBJ_COUNT .o files (+$DELTA this round) ====="

  # sccache stats (best-effort — log even if unavailable)
  sccache --show-stats 2>&1 | sed 's/^/  sccache: /' || true
}

# The trap only helps if this script is still alive after ninja returns, and
# that is exactly what is in doubt: r1 of run 32745725864 went from ninja's
# "received signal: Terminated" straight to the layer export with no further
# line, and three faithful repros (host GNU, Alpine busybox, a ninja that
# drains on SIGTERM) all failed to reproduce it. So also report DURING the
# round, which does not depend on how the round ends and additionally shows
# the hit rate evolving instead of one end-of-round figure.
report_sccache_periodically() {
  while sleep 1800; do
    echo "===== sccache during $LABEL ====="
    sccache --show-stats 2>&1 | sed 's/^/  sccache: /' || true
  done
}
report_sccache_periodically &
SCCACHE_TICKER_PID=$!
trap report_round EXIT
if [[ "$FINAL" != "final" ]]; then
  # A non-final round is MEANT to be cut short, so keep the exit status 0 the
  # way the `|| true` below does — a non-zero rc here would stop BuildKit from
  # committing the partial obj/ layer the next round resumes from. The final
  # round gets no such trap: a signal there is a real failure.
  trap 'report_round; exit 0' TERM
fi

# Final round vs resumable round
if [[ "$FINAL" == "final" ]]; then
  ninja -C "$OUT" -j "$(nproc)" $VARIANT_TARGET
  rc=$?
else
  # 5h hard cap (300m × 60 = 18000s); ninja's own SIGTERM handler drains
  # in-flight jobs, then `timeout` exits 124. That is the ONLY non-zero status a
  # healthy round produces, and the layer still has to commit so the next round
  # can resume from whatever obj/ holds.
  #
  # `|| nrc=$?` rather than a bare call: this script runs under `set -e`, so an
  # unguarded non-zero here kills it before the next line and every round would
  # die at the time box. Nor a blanket `|| true`, which is what let run
  # 34405297193 report r1..r12 green while ninja refused to build at all —
  # twelve rounds, two hours of runner time, zero object files, and only the
  # `final` layer ever went red. Run 32739278406 was the same shape, stopping at
  # 2842/38707 on a missing dawn tool, and run 34432340655 the same again with a
  # compile error 21 objects in.
  #
  # So: 124 commits the partial obj/ exactly as before, and anything else fails
  # the round HERE. Resuming past a real ninja error does not help — the next
  # round re-runs the same failing edge — so the objects this round did write
  # are not worth the eleven rounds it costs to discover that.
  # https://github.com/jclaveau/ci-prebuilds/issues/108
  nrc=0
  timeout 18000 ninja -C "$OUT" -j "$(nproc)" $VARIANT_TARGET || nrc=$?
  if (( nrc != 0 && nrc != 124 )); then
    NOW_OBJ_COUNT=$(find "$OUT" -name '*.o' 2>/dev/null | wc -l)
    echo "ERROR: ninja $LABEL exited $nrc without reaching the 5h cap" >&2
    echo "       (+$((NOW_OBJ_COUNT - PRE_OBJ_COUNT)) object files this round)." >&2
    echo "       That is a build failure, not a time-box kill. Failing the round" >&2
    echo "       rather than resuming into the same error eleven more times." >&2
    exit "$nrc"
  fi
  rc=0
fi

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
