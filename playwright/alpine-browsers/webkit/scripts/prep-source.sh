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

# Playwright.closePage parity with the browser PW actually ships.
#
# playwright-core closes every WebKit page through Playwright.closePage
# (wkPage.ts, WKPage.closePage), and Page._close() then awaits closedPromise,
# which settles only when the browser emits Playwright.pageProxyDestroyed. Our
# build answers -32601 "Unknown method"; sendMayFail swallows that, so the call
# resolves, the page is never closed, the event never arrives and page.close()
# blocks until the surrounding timeout. That is the ~2 minute
# launchPersistentContext and the two live pageProxies where one is expected.
#
# The tag's patch series still closes pages the old way, through
# PageInspectorTargetProxy::close (Target.close). PW's client moved to
# Playwright.closePage and their webkit-2336 build has the command: the
# protocol.json inside their zip declares 21 commands, the pinned base plus
# bootstrap.diff yields 20, and closePage is the whole difference. Same disease
# as patch_page_override_settings above, same fix shape — the WebPageProxy
# methods already exist and bootstrap.diff itself calls them in four places,
# only the inspector plumbing is missing.
#
# Not patched here: Cookie/SetCookieParam gained a partitionKey property in the
# same drift. The client sends it only when set and reads it as optional, so it
# costs nothing until a partitioned-cookie test runs; adding it needs the
# WebKit-side cookie plumbing too. Revisit if conformance shows cookie failures.
#
# Drop this block once PW rolls its base past the commit that adds closePage —
# bootstrap.diff will declare it and the early return below will say so.
patch_playwright_close_page() {
  local json=Source/JavaScriptCore/inspector/protocol/Playwright.json
  local agent_h=Source/WebKit/UIProcess/InspectorPlaywrightAgent.h
  local agent=Source/WebKit/UIProcess/InspectorPlaywrightAgent.cpp

  if grep -q '"closePage"' "$json"; then
    echo "  Playwright.json already carries closePage — PW rolled its base, drop patch_playwright_close_page"
    return 0
  fi

  echo "  add Playwright.closePage (protocol + agent)"
  awk '
    /"name": "setPageZoomFactor",/ { seen = 1 }
    seen && !done && /^        },$/ {
      print
      print "        {"
      print "            \"name\": \"closePage\","
      print "            \"description\": \"Closes the page, destroying the page proxy. Works for both live and crashed pages.\","
      print "            \"parameters\": ["
      print "                { \"name\": \"pageProxyId\", \"$ref\": \"PageProxyID\", \"description\": \"Unique identifier of the page proxy.\" },"
      print "                { \"name\": \"runBeforeUnload\", \"type\": \"boolean\", \"optional\": true, \"description\": \"Whether to run the beforeunload page handlers.\" }"
      print "            ]"
      print "        },"
      done = 1
      next
    }
    { print }
  ' "$json" > "$json.new" && mv "$json.new" "$json"

  awk '
    !done && /setPageZoomFactor\(const String& pageProxyID/ {
      print
      print "    Inspector::Protocol::ErrorStringOr<void> closePage(const String& pageProxyID, std::optional<bool>&& runBeforeUnload) override;"
      done = 1
      next
    }
    { print }
  ' "$agent_h" > "$agent_h.new" && mv "$agent_h.new" "$agent_h"

  awk '
    /ErrorStringOr<void> InspectorPlaywrightAgent::setPageZoomFactor/ { seen = 1 }
    seen && !done && /^}$/ {
      print
      print ""
      print "Inspector::Protocol::ErrorStringOr<void> InspectorPlaywrightAgent::closePage(const String& pageProxyID, std::optional<bool>&& runBeforeUnload)"
      print "{"
      print "    auto* pageProxyChannel = m_pageProxyChannels.get(pageProxyID);"
      print "    if (!pageProxyChannel)"
      print "        return makeUnexpected(\"Unknown pageProxyID\"_s);"
      print ""
      print "    // Mirrors PageInspectorTargetProxy::close: tryClose() runs the"
      print "    // beforeunload handlers, closePage() skips them."
      print "    if (runBeforeUnload.value_or(false))"
      print "        pageProxyChannel->page().tryClose();"
      print "    else"
      print "        pageProxyChannel->page().closePage();"
      print "    return { };"
      print "}"
      done = 1
      next
    }
    { print }
  ' "$agent" > "$agent.new" && mv "$agent.new" "$agent"

  local in_json in_h in_cpp
  in_json=$(grep -c '"closePage"' "$json")
  in_h=$(grep -c 'closePage(const String& pageProxyID' "$agent_h")
  in_cpp=$(grep -c 'InspectorPlaywrightAgent::closePage' "$agent")
  if [[ "$in_json" != 1 ]] || [[ "$in_h" != 1 ]] || [[ "$in_cpp" != 1 ]]; then
    echo "ERROR: closePage appears $in_json/$in_h/$in_cpp time(s) in json/h/cpp, expected 1 each" >&2
    exit 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json" \
      || { echo "ERROR: $json is not valid JSON after patch" >&2; exit 1; }
  fi
}
patch_playwright_close_page

# Page.snapshotRect image format parity with the browser PW actually ships.
#
# playwright-core asks for the screenshot format over the wire —
# `Page.snapshotRect({ format: 'jpeg' | 'webp' | 'png', quality })` — and on
# Linux it does NOT re-encode client-side (wkPage.ts recodes only on darwin).
# It then strips the `data:image/<fmt>;base64,` prefix WITHOUT checking the
# mime, so whatever we encode is handed to the caller as if it were the
# requested format.
#
# The tag's patch series adds only `omitDeviceScaleFactor` to snapshotRect and
# still hardcodes `encodeDataURL(..., "image/png")`, so every screenshot comes
# back PNG. Symptoms, all one root cause: `Error: WebP decode failed`,
# `Error: SOI not found` for jpeg, and "quality option" tests failing because
# PNG ignores quality. PNG-format tests pass, which is why this looked like a
# webp-specific problem for a long time (it is not — see
# project_wk_webp_dead_hypotheses).
#
# Same drift as patch_playwright_close_page: PW's shipped webkit-2336
# protocol.json declares snapshotRect with `format` + `quality` and a
# Page.ImageFormat enum; the pinned base plus bootstrap.diff declares neither.
# A full domain-by-domain diff of their protocol.json against ours found
# exactly these two gaps plus the closePage one, nothing else.
#
# Semantics come from their protocol.json's own description: quality is ignored
# for png, defaults to 80 for jpeg, and for webp an omitted quality or 100
# means lossless. The Skia encoders are all compiled in already
# (SkJpegEncoder/SkWebpEncoder/SkPngEncoder in ImageUtilitiesSkia.cpp) and take
# quality as a 0..1 double — but at the pinned base the webp path never sets
# fCompression, so "lossless by default" needs the upstream webpEncoderOptions
# helper backported too (WebKit main added it after our base).
patch_page_snapshot_format() {
  local json=Source/JavaScriptCore/inspector/protocol/Page.json
  local agent_h=Source/WebCore/inspector/agents/InspectorPageAgent.h
  local agent=Source/WebCore/inspector/agents/InspectorPageAgent.cpp
  local skia=Source/WebCore/platform/graphics/skia/ImageUtilitiesSkia.cpp

  for f in "$json" "$agent_h" "$agent" "$skia"; do
    [[ -f "$f" ]] || { echo "ERROR: expected $f to exist" >&2; exit 1; }
  done

  if grep -q '"ImageFormat"' "$json"; then
    echo "  Page.json already carries ImageFormat — PW rolled its base, drop patch_page_snapshot_format"
    return 0
  fi

  echo "  add Page.ImageFormat + snapshotRect format/quality (protocol + agent + skia)"

  awk '
    !done_type && /^    "types": \[$/ {
      print
      print "        {"
      print "            \"id\": \"ImageFormat\","
      print "            \"type\": \"string\","
      print "            \"enum\": [\"png\", \"jpeg\", \"webp\"],"
      print "            \"description\": \"Image format used to encode a captured snapshot.\""
      print "        },"
      done_type = 1
      next
    }
    !done_param && /"name": "omitDeviceScaleFactor"/ {
      sub(/\}$/, "},")
      print
      print "                { \"name\": \"format\", \"$ref\": \"ImageFormat\", \"optional\": true, \"description\": \"Image format of the resulting snapshot. Defaults to \\\"png\\\".\" },"
      print "                { \"name\": \"quality\", \"type\": \"integer\", \"optional\": true, \"description\": \"Compression quality from 0 to 100 (ignored for the \\\"png\\\" format). For \\\"jpeg\\\" it defaults to 80. For \\\"webp\\\", omitting the quality or setting it to 100 produces a lossless image; any other value uses lossy compression at that quality.\" }"
      done_param = 1
      next
    }
    { print }
  ' "$json" > "$json.new" && mv "$json.new" "$json"

  awk '
    !done && /ErrorStringOr<String> snapshotRect\(int x, int y, int width, int height, Inspector::Protocol::Page::CoordinateSystem, std::optional<bool>&& omitDeviceScaleFactor\);/ {
      sub(/std::optional<bool>&& omitDeviceScaleFactor\);/, "std::optional<bool>\\&\\& omitDeviceScaleFactor, std::optional<Inspector::Protocol::Page::ImageFormat>\\&\\& format, std::optional<int>\\&\\& quality);")
      done = 1
    }
    { print }
  ' "$agent_h" > "$agent_h.new" && mv "$agent_h.new" "$agent_h"

  # Two encodeDataURL(..., "image/png") call sites exist (snapshotNode and
  # snapshotRect); only the latter takes a format, so gate on having seen the
  # snapshotRect definition first.
  awk '
    /ErrorStringOr<String> InspectorPageAgent::snapshotRect\(/ {
      sub(/std::optional<bool>&& omitDeviceScaleFactor\)/, "std::optional<bool>\\&\\& omitDeviceScaleFactor, std::optional<Inspector::Protocol::Page::ImageFormat>\\&\\& format, std::optional<int>\\&\\& quality)")
      in_rect = 1
      print
      next
    }
    in_rect && !done && /return encodeDataURL\(WTF::move\(snapshot\), "image\/png"_s\);/ {
      print "    String mimeType = \"image/png\"_s;"
      print "    std::optional<int> defaultQuality;"
      print "    if (format) {"
      print "        switch (*format) {"
      print "        case Inspector::Protocol::Page::ImageFormat::Png:"
      print "            break;"
      print "        case Inspector::Protocol::Page::ImageFormat::Jpeg:"
      print "            mimeType = \"image/jpeg\"_s;"
      print "            defaultQuality = 80;"
      print "            break;"
      print "        case Inspector::Protocol::Page::ImageFormat::Webp:"
      print "            mimeType = \"image/webp\"_s;"
      print "            // An omitted quality (or 100) means lossless, which the"
      print "            // encoder selects at 1.0."
      print "            defaultQuality = 100;"
      print "            break;"
      print "        }"
      print "    }"
      print ""
      print "    std::optional<double> encodeQuality;"
      print "    if (defaultQuality) {"
      print "        int value = quality.value_or(*defaultQuality);"
      print "        if (value < 0)"
      print "            value = 0;"
      print "        else if (value > 100)"
      print "            value = 100;"
      print "        encodeQuality = value / 100.0;"
      print "    }"
      print ""
      print "    return encodeDataURL(WTF::move(snapshot), mimeType, encodeQuality);"
      done = 1
      next
    }
    { print }
  ' "$agent" > "$agent.new" && mv "$agent.new" "$agent"

  # Backport upstream's webpEncoderOptions: at the pinned base neither webp
  # path sets fCompression, so quality 100 is lossy and PW's "webp screenshots
  # should be lossless by default" fails. Replaces the two-line quality block
  # that follows each `SkWebpEncoder::Options options;`.
  awk '
    /^static sk_sp<SkData> encodeAcceleratedImage\(/ && !done_fn {
      print "static SkWebpEncoder::Options webpEncoderOptions(std::optional<double> quality)"
      print "{"
      print "    SkWebpEncoder::Options options;"
      print "    if (quality && *quality == 1.0) {"
      print "        // A quality of 1.0 selects lossless compression. For lossless encoding"
      print "        // fQuality is the compression effort rather than the visual quality."
      print "        options.fCompression = SkWebpEncoder::Compression::kLossless;"
      print "        options.fQuality = 75;"
      print "    } else if (quality && *quality >= 0.0 && *quality < 1.0)"
      print "        options.fQuality = static_cast<int>(*quality * 100.0 + 0.5);"
      print "    return options;"
      print "}"
      print ""
      done_fn = 1
    }
    /SkWebpEncoder::Options options;$/ {
      sub(/SkWebpEncoder::Options options;/, "SkWebpEncoder::Options options = webpEncoderOptions(quality);")
      print
      skip = 2
      next
    }
    skip > 0 { skip--; next }
    { print }
  ' "$skia" > "$skia.new" && mv "$skia.new" "$skia"

  local n_type n_param n_h n_cpp n_skia_fn n_skia_use
  n_type=$(grep -c '"id": "ImageFormat"' "$json")
  n_param=$(grep -c '"name": "format", "\$ref": "ImageFormat"' "$json")
  n_h=$(grep -c 'ImageFormat>&& format' "$agent_h")
  n_cpp=$(grep -c 'ImageFormat::Webp:' "$agent")
  n_skia_fn=$(grep -c '^static SkWebpEncoder::Options webpEncoderOptions' "$skia")
  n_skia_use=$(grep -c 'webpEncoderOptions(quality);' "$skia")
  if [[ "$n_type" != 1 ]] || [[ "$n_param" != 1 ]] || [[ "$n_h" != 1 ]] \
     || [[ "$n_cpp" != 1 ]] || [[ "$n_skia_fn" != 1 ]] || [[ "$n_skia_use" != 2 ]]; then
    echo "ERROR: snapshot-format patch counts type=$n_type param=$n_param h=$n_h cpp=$n_cpp skia_fn=$n_skia_fn skia_use=$n_skia_use (want 1/1/1/1/1/2)" >&2
    exit 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json" \
      || { echo "ERROR: $json is not valid JSON after patch" >&2; exit 1; }
  fi
}
patch_page_snapshot_format

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

# Strip .git — ~1GB saved in the source-prep image which both port chains FROM.
rm -rf .git

echo "===== Source ready at $SRC ($(du -sh "$SRC" | cut -f1)) ====="
