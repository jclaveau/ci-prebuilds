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

# WebRTC parity (added by prep-source.sh): the WPE/GTK ports default ENABLE_WEB_RTC
# to ${ENABLE_EXPERIMENTAL_FEATURES} (=OFF), so RTCPeerConnection/RTCDataChannel are
# never compiled → tests/library/modernizr.spec.ts fails on peerconnection:false +
# datachannel:false. Force it ON for both ports. Like ENABLE_ORIENTATION_EVENTS this
# is a PRIVATE port value (a CLI -D in cmake-flags.overlay does NOT override it), so
# edit the source. USE_GSTREAMER_WEBRTC needs no change: it defaults ON (PUBLIC) and
# is WEBKIT_OPTION_DEPEND'd on ENABLE_WEB_RTC → enabling WEB_RTC auto-selects the
# GStreamer webrtcbin backend and keeps USE_LIBWEBRTC FALSE (no libwebrtc vendoring).
# GStreamerChecks.cmake then needs gstreamer-webrtc-1.0 (gst-plugins-bad-dev, present)
# + OpenSSL>=3 (openssl-dev, added to Dockerfile.source-prep).
force_webrtc_option() {
  local cmake_file="$1"
  if grep -q 'ENABLE_WEB_RTC PRIVATE ${ENABLE_EXPERIMENTAL_FEATURES}' "$cmake_file"; then
    echo "  force ENABLE_WEB_RTC ON in $(basename "$cmake_file")"
    awk '
      /WEBKIT_OPTION_DEFAULT_PORT_VALUE\(ENABLE_WEB_RTC PRIVATE/ {
        print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEB_RTC PRIVATE ON)"; next
      }
      { print }
    ' "$cmake_file" > "${cmake_file}.new"
    mv "${cmake_file}.new" "$cmake_file"
  fi
  if ! grep -q 'ENABLE_WEB_RTC PRIVATE ON' "$cmake_file"; then
    echo "ERROR: failed to force ENABLE_WEB_RTC ON in $(basename "$cmake_file")" >&2
    exit 1
  fi
}
force_webrtc_option Source/cmake/OptionsWPE.cmake
force_webrtc_option Source/cmake/OptionsGTK.cmake

# Drop flite TTS voices (~11 MB shipped per port): PW's bootstrap.diff force-
# enables ENABLE_SPEECH_SYNTHESIS (PRIVATE ON) for both ports, dragging the
# flite engine + 4 voice-data libs into every bundle. Headless automation never
# synthesizes speech (PW's speech tests are chromium-only), so flip the port
# default OFF. PRIVATE makes it non-user-toggleable — a CLI -D can't override,
# hence the source edit (same shape as force_webrtc_option above).
force_speech_synthesis_off() {
  local cmake_file="$1"
  if grep -q 'ENABLE_SPEECH_SYNTHESIS PRIVATE ON' "$cmake_file"; then
    echo "  force ENABLE_SPEECH_SYNTHESIS OFF in $(basename "$cmake_file")"
    awk '
      /WEBKIT_OPTION_DEFAULT_PORT_VALUE\(ENABLE_SPEECH_SYNTHESIS PRIVATE ON\)/ {
        print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_SPEECH_SYNTHESIS PRIVATE OFF)"; next
      }
      { print }
    ' "$cmake_file" > "${cmake_file}.new"
    mv "${cmake_file}.new" "$cmake_file"
  fi
  if grep -q 'ENABLE_SPEECH_SYNTHESIS PRIVATE ON' "$cmake_file"; then
    echo "ERROR: failed to force ENABLE_SPEECH_SYNTHESIS OFF in $(basename "$cmake_file")" >&2
    exit 1
  fi
}
force_speech_synthesis_off Source/cmake/OptionsWPE.cmake
force_speech_synthesis_off Source/cmake/OptionsGTK.cmake

# GTK defaults USE_LIBRICE ON (Rust librice ICE backend); Alpine has no librice →
# GStreamerChecks.cmake FATAL_ERRORs at configure. Force OFF so the GStreamer WebRTC
# backend uses libnice. WPE has no USE_LIBRICE port default (uses libnice already).
if grep -q 'WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_LIBRICE PRIVATE ON)' Source/cmake/OptionsGTK.cmake; then
  echo "  force USE_LIBRICE OFF in OptionsGTK.cmake"
  awk '
    /WEBKIT_OPTION_DEFAULT_PORT_VALUE\(USE_LIBRICE PRIVATE ON\)/ {
      print "WEBKIT_OPTION_DEFAULT_PORT_VALUE(USE_LIBRICE PRIVATE OFF)"; next
    }
    { print }
  ' Source/cmake/OptionsGTK.cmake > Source/cmake/OptionsGTK.cmake.new
  mv Source/cmake/OptionsGTK.cmake.new Source/cmake/OptionsGTK.cmake
fi

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

# NetworkDataTaskSoup::download() opens the automation download destination
# with g_file_replace/g_file_create, which do NOT create parent directories.
# PW's `should save downloads to artifactsDir` passes a *user-provided*
# artifactsDir as the download path, and neither PW (browserType only mkdirs
# the auto mkdtemp path, not a caller-supplied one) nor WebKit-soup creates it
# — so the write fails with `Error opening file …/artifacts/<uuid>: No such
# file or directory` (ENOENT). Proven locally: pre-creating the dir makes the
# test pass. Insert an idempotent mkdir -p of the destination's parent before
# the stream open. Pure glib, no new include (GFile/GRefPtr already in scope).
SOUP_FILE="Source/WebKit/NetworkProcess/soup/NetworkDataTaskSoup.cpp"
if [[ -f "$SOUP_FILE" ]] && ! grep -q 'download destination parent' "$SOUP_FILE"; then
  echo "  inject download-destination mkdir -p into $(basename "$SOUP_FILE")"
  awk '
    !done && /m_downloadDestinationFile = adoptGRef\(g_file_new_for_path\(downloadDestinationPath\.data\(\)\)\);/ {
      print
      print "    // Playwright/Alpine parity (added by prep-source.sh): create the"
      print "    // download destination parent dir; g_file_replace/g_file_create do"
      print "    // not mkdir -p and a user-provided artifactsDir is created by no one."
      print "    if (GRefPtr<GFile> downloadParentDir = adoptGRef(g_file_get_parent(m_downloadDestinationFile.get())))"
      print "        g_file_make_directory_with_parents(downloadParentDir.get(), nullptr, nullptr);"
      done = 1
      next
    }
    { print }
  ' "$SOUP_FILE" > "${SOUP_FILE}.new"
  mv "${SOUP_FILE}.new" "$SOUP_FILE"
  if ! grep -q 'download destination parent' "$SOUP_FILE"; then
    echo "ERROR: failed to inject download-destination mkdir -p (anchor not found?)" >&2
    exit 1
  fi
fi

# Strip .git — ~1GB saved in the source-prep image which both port chains FROM.
rm -rf .git

echo "===== Source ready at $SRC ($(du -sh "$SRC" | cut -f1)) ====="
