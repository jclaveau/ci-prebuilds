#!/usr/bin/env bash
# One-shot source preparation, runs in Dockerfile.source-prep.
#
# Clones WebKit at PW's pinned SHA, applies PW's patch series, copies the
# embedder/ overrides, appends WPE-port feature-parity options (PW only
# patches OptionsGTK.cmake; OptionsWPE.cmake inherits upstream defaults
# which miss DEVICE_ORIENTATION etc., causing compile errors), and strips
# .git to save ~1GB in the resulting image.
#
# Usage: prep-source.sh <work_dir>

set -euo pipefail

WORK="${1:?usage: prep-source.sh <work_dir>}"
PW="$WORK/pw-webkit"
SRC="$WORK/webkit-src"

[[ -f "$PW/UPSTREAM_CONFIG.sh" ]] || { echo "missing $PW/UPSTREAM_CONFIG.sh" >&2; exit 1; }

PW_SHA=$(awk -F= '$1=="BASE_REVISION"{gsub(/[" ]/,"",$2); print $2; exit}' "$PW/UPSTREAM_CONFIG.sh")
PW_WEBKIT_VER=$(cat "$PW/.webkit-version")
PW_WEBKIT_REV=$(cat "$PW/.webkit-revision")
echo "Cloning WebKit/WebKit at $PW_SHA (PW v${PW_VERSION:-?} → revision $PW_WEBKIT_REV, browserVersion $PW_WEBKIT_VER)"

mkdir -p "$SRC"
git init -q "$SRC"
git -C "$SRC" remote add origin https://github.com/WebKit/WebKit.git 2>/dev/null || true
git -C "$SRC" fetch --depth=1 origin "$PW_SHA"
git -C "$SRC" reset --hard FETCH_HEAD --quiet
git -C "$SRC" log -1 --format='%h %s' || true

cd "$SRC"

shopt -s nullglob
PATCHES=("$PW/patches"/*.patch "$PW/patches"/*.diff)
if (( ${#PATCHES[@]} == 0 )); then
  echo "WARN: no patches found under $PW/patches/ — building unmodified upstream WebKit at $PW_SHA"
else
  for p in "${PATCHES[@]}"; do
    echo "  apply pw/$(basename "$p")"
    patch -p1 -i "$p"
  done
fi
shopt -u nullglob

if [[ -d "$PW/embedder" ]] && [[ -n "$(ls -A "$PW/embedder" 2>/dev/null)" ]]; then
  echo "  copy PW embedder overrides"
  cp -aR "$PW/embedder"/. .
fi

# PW's bootstrap.diff flips ENABLE_ORIENTATION_EVENTS 0→1 in PlatformEnable.h,
# but ENABLE_ORIENTATION_EVENTS is a WEBKIT_OPTION_DEFINE'd cmake option, so
# the generated cmakeconfig.h emits `#define ENABLE_ORIENTATION_EVENTS 0`
# first — PlatformEnable.h's `#if !defined` guard then skips its own #define.
# PW's source patch adds an *unguarded* call to Page::setOverrideOrientation
# in WebPage.cpp's constructor and the method body in WebCore::Page is
# gated by ENABLE(ORIENTATION_EVENTS), so BOTH ports fail to compile without
# this port default. WEBKIT_OPTION_DEFAULT_PORT_VALUE asserts
# (`_ENSURE_OPTION_MODIFICATION_IS_ALLOWED`) that it's called between
# WEBKIT_OPTION_BEGIN() and WEBKIT_OPTION_END() — so we INSERT before the END
# line, not append at EOF.
patch_orientation_events() {
  local cmake_file="$1"
  local port_tag="$2"
  if ! grep -q "Playwright ${port_tag} port parity" "$cmake_file"; then
    echo "  insert ENABLE_ORIENTATION_EVENTS port default into $(basename "$cmake_file")"
    awk -v tag="$port_tag" '
      /WEBKIT_OPTION_END\(\)/ && !done {
        print "# Playwright " tag " port parity (added by prep-source.sh)."
        print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ORIENTATION_EVENTS PRIVATE ON)"
        done = 1
      }
      { print }
    ' "$cmake_file" > "${cmake_file}.new"
    mv "${cmake_file}.new" "$cmake_file"
    if ! grep -q "Playwright ${port_tag} port parity" "$cmake_file"; then
      echo "ERROR: failed to insert ${port_tag} parity options (no WEBKIT_OPTION_END found?)" >&2
      exit 1
    fi
  fi
}
patch_orientation_events Source/cmake/OptionsWPE.cmake WPE
patch_orientation_events Source/cmake/OptionsGTK.cmake GTK

# DrawingAreaCoordinatedGraphicsGLib.cpp (GTK port only) calls tracePoint()
# and WTFEmitSignpost() without explicitly including <wtf/SystemTracing.h>;
# upstream relies on it coming via transitive includes. On Alpine/musl with
# clang's unified-source bucketing here, the transitive chain is broken and
# both `tracePoint` and the `RenderingUpdateRunLoopObserver*` enum members
# resolve as undeclared. Patch the .cpp to add the include directly — keeps
# the fix scoped to this one file (other tracePoint call sites in WebKit/GTK
# code paths are inside .cpps that DO include SystemTracing.h transitively).
DACG_FILE="Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/DrawingAreaCoordinatedGraphicsGLib.cpp"
if [[ -f "$DACG_FILE" ]] && ! grep -q '<wtf/SystemTracing.h>' "$DACG_FILE"; then
  echo "  inject <wtf/SystemTracing.h> include into $(basename "$DACG_FILE")"
  awk '
    !done && /^#include "WebProcess.h"/ {
      print
      print "#include <wtf/SystemTracing.h>"
      done = 1
      next
    }
    { print }
  ' "$DACG_FILE" > "${DACG_FILE}.new"
  mv "${DACG_FILE}.new" "$DACG_FILE"
fi

# Strip .git — ~1GB saved in the source-prep image which both port chains FROM.
rm -rf .git

echo "===== Source ready at $SRC ($(du -sh "$SRC" | cut -f1)) ====="
