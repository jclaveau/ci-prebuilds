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

# PW's bootstrap.diff patches Source/cmake/OptionsGTK.cmake to enable several
# features (DEVICE_ORIENTATION, APPLICATION_MANIFEST, CURSOR_VISIBILITY,
# GAMEPAD, POINTER_LOCK, SPEECH_SYNTHESIS) but doesn't touch OptionsWPE.cmake.
# Their source-level patches (e.g. WebPage.cpp adding setOverrideOrientation)
# reference APIs gated by those flags, so the WPE port fails to compile
# without these defaults. WEBKIT_OPTION_DEFAULT_PORT_VALUE PRIVATE values
# aren't user-toggleable from the cmake CLI, so we patch the file directly.
#
# WEBKIT_OPTION_DEFAULT_PORT_VALUE asserts (`_ENSURE_OPTION_MODIFICATION_IS_
# ALLOWED`) that it's called between WEBKIT_OPTION_BEGIN() and
# WEBKIT_OPTION_END() — so we INSERT before the END line, not append at EOF.
if ! grep -q "Playwright WPE port parity" Source/cmake/OptionsWPE.cmake; then
  echo "  insert PW-GTK feature parity defaults into OptionsWPE.cmake"
  awk '
    /WEBKIT_OPTION_END\(\)/ && !done {
      print "# Playwright WPE port parity (added by prep-source.sh)."
      print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_APPLICATION_MANIFEST PRIVATE ON)"
      print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_CURSOR_VISIBILITY PRIVATE ON)"
      print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_DEVICE_ORIENTATION PRIVATE ON)"
      print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_GAMEPAD PRIVATE ON)"
      print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_POINTER_LOCK PRIVATE ON)"
      print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SPEECH_SYNTHESIS PRIVATE ON)"
      done = 1
    }
    { print }
  ' Source/cmake/OptionsWPE.cmake > Source/cmake/OptionsWPE.cmake.new
  mv Source/cmake/OptionsWPE.cmake.new Source/cmake/OptionsWPE.cmake
  if ! grep -q "Playwright WPE port parity" Source/cmake/OptionsWPE.cmake; then
    echo "ERROR: failed to insert WPE parity options (no WEBKIT_OPTION_END found?)" >&2
    exit 1
  fi
fi

# Strip .git — ~1GB saved in the source-prep image which both port chains FROM.
rm -rf .git

echo "===== Source ready at $SRC ($(du -sh "$SRC" | cut -f1)) ====="
