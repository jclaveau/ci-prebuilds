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

# Page.overrideSetting parity with the browser PW actually ships.
#
# playwright-core sends seven Page.overrideSetting calls while creating a page,
# and rejecting any one of them fails newPage outright:
#
#   browserContext.newPage: Protocol error (Page.overrideSetting):
#   Unknown setting: PushAPIEnabled
#
# WebKit 5e67bf8293 (2026-07-13) upstreamed five of PW's settings and added
# PushAPIEnabled, and the PW client started sending all seven of what it now
# had. But browser_patches/webkit/UPSTREAM_CONFIG.sh at tag v1.62.0 still names
# 343e13bf (2026-04-28), three months before that commit. PW's own webkit-2336
# build carries 21 settings (the protocol.json inside their zip says so); the
# pinned base plus the tag's patch series yields 20, missing exactly this one.
# So the pinned SHA cannot reproduce the browser PW ships against — see
# project_pw_release_tag_pins_disagree for the same disease on firefox.
#
# The preference itself already exists at the pinned base (UnifiedWebPreferences
# .yaml, with a WebCore default, so Settings::setPushAPIEnabled is generated);
# only the inspector plumbing is missing. Upstream routes it through
# overrideSettingByModifyingValue, which needs yaml changes that collide with
# how bootstrap.diff implements its own five; PW's plain
# `setX(value.value_or(false))` idiom needs nothing and is what the neighbouring
# cases already use. Drop this block once PW rolls its base past 5e67bf8293 (at
# which point bootstrap.diff has to stop adding the five, so it will be
# obvious).
#
# Verified by applying bootstrap.diff's Page.json hunk to the pinned base and
# reading the enum, NOT by grepping the diff: an earlier version of this patch
# also added FixedBackgroundsPaintRelativeToDocument, which bootstrap.diff
# already adds, and the duplicate enumerator only surfaced as a compile error
# four WPE rounds later. Hence the exactly-once assertions below.
patch_page_override_settings() {
  local json=Source/JavaScriptCore/inspector/protocol/Page.json
  local agent=Source/WebCore/inspector/agents/InspectorPageAgent.cpp

  if grep -q '"PushAPIEnabled"' "$json"; then
    echo "  Page.Setting already carries PushAPIEnabled — PW rolled its base, drop patch_page_override_settings"
    return 0
  fi

  echo "  add PushAPIEnabled to Page.Setting"
  awk '
    /"AuthorAndUserStylesEnabled",/ && !done {
      print
      print "                \"PushAPIEnabled\","
      done = 1
      next
    }
    { print }
  ' "$json" > "$json.new" && mv "$json.new" "$json"

  awk '
    /^    case Inspector::Protocol::Page::Setting::ScriptEnabled:/ && !done {
      print "    case Inspector::Protocol::Page::Setting::PushAPIEnabled:"
      print "        inspectedPageSettings.setPushAPIEnabled(value.value_or(false));"
      print "        return { };"
      print ""
      done = 1
    }
    { print }
  ' "$agent" > "$agent.new" && mv "$agent.new" "$agent"

  local in_json in_agent
  in_json=$(grep -c '"PushAPIEnabled"' "$json")
  in_agent=$(grep -c "Setting::PushAPIEnabled:" "$agent")
  if [[ "$in_json" != 1 ]] || [[ "$in_agent" != 1 ]]; then
    echo "ERROR: PushAPIEnabled appears $in_json time(s) in $json and $in_agent time(s) in $agent, expected 1 each" >&2
    exit 1
  fi
}
patch_page_override_settings

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

# Keep the right-click release when the input is synthetic.
#
# WebPageProxy::showContextMenu() discards mouse events already queued in the UI
# process, and upstream's own comment says it fires "if we take too long to enter
# the nested runloop". PW's locator.click() PIPELINES move/down/up — the wire
# shows all three sent in one millisecond and acknowledged together — so on our
# musl build the release is already queued when ShowContextMenu arrives and is
# dropped. The page then sees ['mousedown','contextmenu'] and
# tests/page/page-click.spec.ts:1203 fails. Sending the same three events awaited
# one at a time passes, which is what identifies this as the discard rather than
# a dispatch bug.
#
# Immediately above the discard, WebKit already exempts automation:
#     if (RefPtr automationSession = ...processPool().automationSession()) {
#         if (m_controlledByAutomation && automationSession->isSimulatingUserInteraction())
#             return;
# PW drives over the inspector rather than WebAutomationSession, so
# automationSession() is null and it never applies. Extend the same reasoning to
# the discard: when every event was injected by the driver there are no stray
# user events to throw away.
#
# Upstream candidate — worth offering to PW rather than carrying forever.
patch_keep_synthetic_mouse_events() {
  local page_proxy=Source/WebKit/UIProcess/WebPageProxy.cpp

  # Key the guard AND the assertion on our own marker, never on
  # `if (!m_controlledByAutomation)` — that already occurs in
  # activeAutomationSession(), so a generic grep makes this patch a silent
  # no-op on the skip path and a false "applied twice" on the assert path.
  local marker='no stray user events to discard'

  if grep -q "$marker" "$page_proxy"; then
    echo "  showContextMenu already guards the discard — drop patch_keep_synthetic_mouse_events"
    return 0
  fi

  echo "  guard discardQueuedMouseEvents() in showContextMenu"
  # discardQueuedMouseEvents() is called twice (didStartDrag also calls it), so
  # arm on the comment unique to the context-menu one rather than the call.
  awk '
    /MouseDown event that triggered this ShowContextMenu message/ { armed = 1 }
    armed && /^    discardQueuedMouseEvents\(\);$/ {
      print "    // Playwright injects every event over the inspector, so there are"
      print "    // no stray user events to discard here — and its click() pipelines"
      print "    // press and release, so this would otherwise drop the release."
      print "    // See prep-source.sh: patch_keep_synthetic_mouse_events."
      print "    if (!m_controlledByAutomation)"
      print "        discardQueuedMouseEvents();"
      armed = 0
      next
    }
    { print }
  ' "$page_proxy" > "${page_proxy}.new"
  mv "${page_proxy}.new" "$page_proxy"

  local guards
  guards=$(grep -c "$marker" "$page_proxy")
  if [[ "$guards" != 1 ]]; then
    echo "ERROR: guard applied $guards time(s) in $page_proxy, expected exactly 1" >&2
    exit 1
  fi
}
patch_keep_synthetic_mouse_events

# Give automation the mock capture devices it is expected to have.
#
# tests/library/permissions.spec.ts:349-386 (the four "camera and microphone"
# tests) drive getUserMedia and expect live audio+video tracks. They are
# mock-capture-device tests, gated only on isFrozenWebkit (debian11 /
# ubuntu20.04 / macOS<15), so PW's own ubuntu24.04 CI runs and passes them.
#
# The mock centre is off by default on every port and playwright-core never
# turns it on — its shipped bundle sends exactly seven Page.overrideSetting
# calls and this is not one of them, confirmed on the wire on both sides. So we
# enumerate zero devices and every getUserMedia fails OverconstrainedError,
# BEFORE the permission gate, which is why even the ungranted case reports the
# wrong error. Our build is not missing the capability: with the setting
# actually delivered it returns all six mock devices and live tracks, identical
# to upstream.
#
# Enable it when the page is controlled by automation, which is exactly the
# population these tests describe. mockCaptureDevicesPromptEnabled stays on, so
# permission is still required and "should reject when no permission is granted"
# keeps its NotAllowedError — upstream runs with the mock centre on and passes
# that test.
#
# syncWithWebCorePrefs re-derived the same value inline; point it at the
# accessor so the two cannot drift.
patch_mock_capture_for_automation() {
  local umprm=Source/WebKit/UIProcess/UserMediaPermissionRequestManagerProxy.cpp
  local marker='automation is expected to see mock capture devices'

  if grep -q "$marker" "$umprm"; then
    echo "  mock capture already enabled for automation — drop patch_mock_capture_for_automation"
    return 0
  fi

  echo "  enable mock capture devices under automation"
  awk '
    /^    RefPtr page = m_page.get\(\);$/ && !done && prev_is_override {
      print "    RefPtr page = m_page.get();"
      print "    if (!page)"
      print "        return false;"
      print "    // Playwright: automation is expected to see mock capture devices, and the"
      print "    // client never sends the MockCaptureDevicesEnabled override that would turn"
      print "    // them on. See prep-source.sh: patch_mock_capture_for_automation."
      print "    if (page->isControlledByAutomation())"
      print "        return true;"
      print "    return protect(page->preferences())->mockCaptureDevicesEnabled();"
      done = 1
      skip_next_return = 1
      next
    }
    skip_next_return && /^    return page && protect\(page->preferences\(\)\)->mockCaptureDevicesEnabled\(\);$/ {
      skip_next_return = 0
      next
    }
    { prev_is_override = ($0 ~ /return \*m_mockDevicesEnabledOverride;/); print }
  ' "$umprm" > "${umprm}.new"
  mv "${umprm}.new" "$umprm"

  # One predicate, both call sites: syncWithWebCorePrefs duplicated the logic.
  awk '
    /^    bool mockDevicesEnabled = m_mockDevicesEnabledOverride \? \*m_mockDevicesEnabledOverride : preferences->mockCaptureDevicesEnabled\(\);$/ {
      print "    bool mockDevicesEnabled = mockCaptureDevicesEnabled();"
      next
    }
    { print }
  ' "$umprm" > "${umprm}.new"
  mv "${umprm}.new" "$umprm"

  local marks syncs
  marks=$(grep -c "$marker" "$umprm")
  syncs=$(grep -c 'bool mockDevicesEnabled = mockCaptureDevicesEnabled();' "$umprm")
  if [[ "$marks" != 1 ]] || [[ "$syncs" != 1 ]]; then
    echo "ERROR: mock-capture patch applied marker=$marks sync=$syncs in $umprm, expected 1 each" >&2
    exit 1
  fi
}
patch_mock_capture_for_automation

# Say which record the CacheStorage read path is dropping.
#
# DIAGNOSTIC, not a fix. In a persistent context our cache.put() resolves and
# the record file appears on disk exactly where upstream writes it, yet
# cache.keys() is empty and match() returns null in the same document — so the
# write lands and the live read cannot see it. readAllRecordInfosInternal drops
# a record on a failed read AND on a failed decode, both with a bare `continue`
# and no trace, so the build cannot currently say which. The decode is the
# likelier of the two (it verifies a salt-derived SHA1, and the profile carries
# two salt files), but "likelier" is not a reason to patch blind.
patch_log_dropped_cache_records() {
  local disk_store=Source/WebKit/NetworkProcess/storage/CacheStorageDiskStore.cpp
  local marker='ALPINE-DIAG'

  if grep -q "$marker" "$disk_store"; then
    echo "  cache record drops already logged — drop patch_log_dropped_cache_records"
    return 0
  fi

  echo "  log dropped CacheStorage records"
  # Both edits must stay BRACED. The first attempt emitted the log as a bare
  # statement under `if (!fileData)`, which left `continue;` unconditional and
  # would have skipped every record — the diagnostic destroying the thing it
  # measures. The decode edit appends an `else` rather than re-testing, so
  # readRecordInfoFromFileData is still called exactly once per record.
  awk '
    /^                if \(!fileData\)$/ {
      print "                if (!fileData) {"
      print "                    RELEASE_LOG_ERROR(CacheStorage, \"ALPINE-DIAG readAllRecordInfos: unreadable record file\");"
      print "                    continue;"
      print "                }"
      skip_continue = 1
      next
    }
    skip_continue && /^                    continue;$/ { skip_continue = 0; next }
    /^                    recordInfos.append\(WTF::move\(storedRecordInfo->info\)\);$/ {
      print
      print "                else"
      print "                    RELEASE_LOG_ERROR(CacheStorage, \"ALPINE-DIAG readAllRecordInfos: record failed to decode\");"
      next
    }
    { print }
  ' "$disk_store" > "${disk_store}.new"
  mv "${disk_store}.new" "$disk_store"

  local logs
  logs=$(grep -c "$marker" "$disk_store")
  if [[ "$logs" != 2 ]]; then
    echo "ERROR: cache-drop logging applied $logs time(s) in $disk_store, expected 2" >&2
    exit 1
  fi
}
patch_log_dropped_cache_records

# Strip .git — ~1GB saved in the source-prep image which both port chains FROM.
rm -rf .git

echo "===== Source ready at $SRC ($(du -sh "$SRC" | cut -f1)) ====="
