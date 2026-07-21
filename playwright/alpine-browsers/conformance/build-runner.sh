#!/usr/bin/env bash
# Build a candidate Alpine runner image that consumes our browser artifact at
# PW SDK's auto-discovery cache path, so the upstream PW test suite finds the
# binary without any playwright.config.ts override.
#
# Required env (passed from the reusable workflow):
#   BROWSER         — chromium | firefox | webkit
#   IMAGE_REF       — full artifact image ref (registry/repo:tag) to COPY --from
#   PW_VERSION      — PW pin to install via `npm install -g playwright@${VER}`
#   ARTIFACT_REV    — browser revision (chs CHS_REV, ff revision, wk revision)
#                     used to stage at PW's cache-path layout
#   IMAGE_TAG_OUT   — local tag to assign the runner (default: pw-conformance-runner:latest)
#
# Why a separate runner image per call: each browser needs different runtime
# apks (libxul deps for FF, gtk/wpe libs for WebKit, near-nothing for chromium
# since the artifact bundles its own .so set). Mirrors the smoke-* jobs.

set -euo pipefail

: "${BROWSER:?BROWSER must be set}"
: "${IMAGE_REF:?IMAGE_REF must be set}"
: "${PW_VERSION:?PW_VERSION must be set}"
: "${ARTIFACT_REV:?ARTIFACT_REV must be set}"
IMAGE_TAG_OUT="${IMAGE_TAG_OUT:-pw-conformance-runner:latest}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

case "$BROWSER" in
  chromium)
    # The apk-based chromium bundles most .so files inside the artifact tree so
    # a minimal Alpine runner sufficed. From-source chromium (chs-fs-sha-*) is
    # dynamically linked against system libs — full runtime-dep list per
    # project_chromium_from_source_runtime_deps. Both variants safely accept
    # the wider list; extra apks don't hurt the apk path.
    cat > "$TMPDIR/Dockerfile" <<EOF
FROM alpine:3.22
RUN apk update && apk add --no-cache \\
    nodejs npm bash git \\
    ca-certificates font-opensans ttf-freefont \\
    nss freetype harfbuzz libdrm mesa-gl \\
    libwebp libwebpdemux libxcomposite libxdamage libxrandr libxscrnsaver libxtst \\
    libx11 libxcb libxext libxi cups-libs alsa-lib dbus-libs pango cairo \\
    opus dav1d ffmpeg-libavformat libjpeg-turbo libxslt \\
    libatk-1.0 libatk-bridge-2.0 at-spi2-core minizip \\
    double-conversion crc32c libxkbcommon mesa-gbm eudev-libs flac \\
    harfbuzz-subset \\
    chromium xvfb-run \\
 && mkdir -p /opt/google/chrome \\
 && ln -sf /usr/bin/chromium /opt/google/chrome/chrome
COPY --from=${IMAGE_REF} \\
     /chrome-headless-shell-linux64 \\
     /ms-playwright/chromium_headless_shell-${ARTIFACT_REV}/chrome-headless-shell-linux64
RUN touch /ms-playwright/chromium_headless_shell-${ARTIFACT_REV}/INSTALLATION_COMPLETE
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g playwright@${PW_VERSION}
# browserType.executablePath() resolves to /ms-playwright/chromium-<rev>/
# chrome-linux64/chrome (the full chromium, NOT headless-shell), which the
# conformance tests never launch but `executablePath should work` existsSync-
# checks. Stage the binary there (symlink the headless-shell binary) so the
# check passes. Rev looked up from browsers.json to stay PW-version-correct.
RUN PWC_JSON=\$(find /usr/local/lib/node_modules -name browsers.json -path '*playwright-core*' | head -1) \\
 && CHR_REV=\$(node -e "console.log(require('\$PWC_JSON').browsers.find(b=>b.name==='chromium').revision)") \\
 && mkdir -p /ms-playwright/chromium-\${CHR_REV}/chrome-linux64 \\
 && ln -sf /ms-playwright/chromium_headless_shell-${ARTIFACT_REV}/chrome-headless-shell-linux64/chrome-headless-shell \\
      /ms-playwright/chromium-\${CHR_REV}/chrome-linux64/chrome \\
 && touch /ms-playwright/chromium-\${CHR_REV}/INSTALLATION_COMPLETE
# ffmpeg-1011 is bundled by PW's recordVideo / screencast paths; install via
# the PW SDK so the cache layout matches what tests fixture-expect.
RUN playwright install ffmpeg
EOF
    ;;

  firefox)
    # FF runner MUST match the alpine version FF was built against
    # (playwright/alpine-browsers/Dockerfile uses alpine:edge builder). FF
    # binary DT_NEEDED points at edge SONAMEs (libFLAC.so.14 from flac 1.5,
    # libavformat.so.62 from ffmpeg 8.x). alpine:3.22 provides .so.12/.60
    # → runtime SIGSEGV at launch (see run 29306045726 shard 3 diag).
    #
    # 2026-07-15: chromium re-added via multi-stage self-contained bundle at
    # /opt/chromium-bundle/ (isolated from :edge system libs via RPATH
    # \$ORIGIN). Recorder-UI subsystem (inspector, slowmo, debug-controller,
    # selector-generator, trace-viewer, cli-codegen-*) needs a HEADED chromium
    # binary — apk-install from :edge broken post-flac-1.5, so we ship chromium
    # in its own dep tree. FF binary unaffected.
    #
    # Bundle base is :3.22 (chromium 142). Tried :3.23 (chromium 149) on
    # 2026-07-16 to close the gap to PW-pinned 148 for trace-viewer's internal
    # viewer — still whack-a-mole-failed + worker-abort cascade (iter
    # 29494313953), so reverted. Trace-viewer stays whole-file skipped; every
    # other recorder-UI test (inspector/slowmo/selector-generator) passes fine
    # on 142.
    cat > "$TMPDIR/Dockerfile" <<EOF
FROM alpine:3.22 AS chromium-fetch
RUN apk add --no-cache chromium chromium-swiftshader binutils patchelf
RUN mkdir -p /opt/chromium-bundle \\
 && SRC=/usr/lib/chromium && DEST=/opt/chromium-bundle \\
 && cp -aL "\$SRC"/* "\$DEST"/ \\
 && mv "\$DEST"/chromium "\$DEST"/chrome \\
 && for so in \$(ldd "\$DEST"/chrome 2>/dev/null | awk '{print \$3}' | grep '^/'); do \\
      [ -f "\$so" ] && [ ! -f "\$DEST/\$(basename "\$so")" ] && cp -aL "\$so" "\$DEST"/ || true; \\
    done \\
 && for bin in "\$DEST"/chrome_crashpad_handler "\$DEST"/chrome-sandbox; do \\
      [ -f "\$bin" ] || continue; \\
      for so in \$(ldd "\$bin" 2>/dev/null | awk '{print \$3}' | grep '^/'); do \\
        [ -f "\$so" ] && [ ! -f "\$DEST/\$(basename "\$so")" ] && cp -aL "\$so" "\$DEST"/ || true; \\
      done; \\
    done \\
 && for lib in "\$DEST"/*.so*; do \\
      [ -L "\$lib" ] && continue; \\
      for so in \$(ldd "\$lib" 2>/dev/null | awk '{print \$3}' | grep '^/'); do \\
        [ -f "\$so" ] && [ ! -f "\$DEST/\$(basename "\$so")" ] && cp -aL "\$so" "\$DEST"/ || true; \\
      done; \\
    done \\
 && for so in libsoftokn3.so libfreebl3.so libnssdbm3.so libnssckbi.so libnsspem.so libsqlite3.so.0 libplc4.so libplds4.so; do \\
      [ -f "/usr/lib/\$so" ] && [ ! -f "\$DEST/\$so" ] && cp -aL "/usr/lib/\$so" "\$DEST"/ || true; \\
    done \\
 && patchelf --set-rpath '\$ORIGIN' "\$DEST"/chrome \\
 && for bin in "\$DEST"/chrome_crashpad_handler "\$DEST"/chrome-sandbox; do \\
      [ -f "\$bin" ] && patchelf --set-rpath '\$ORIGIN' "\$bin" 2>/dev/null || true; \\
    done \\
 && for so in "\$DEST"/*.so*; do [ -L "\$so" ] && continue; patchelf --set-rpath '\$ORIGIN' "\$so" 2>/dev/null || true; done \\
 && "\$DEST"/chrome --version

FROM alpine:edge
RUN apk update && apk add --no-cache \\
    nodejs npm bash git build-base python3 \\
    alsa-lib dbus-libs fontconfig freetype glib gtk+3.0 harfbuzz \\
    icu-libs icu-data-full libevent libffi libjpeg-turbo libnotify libogg \\
    libtheora libvorbis libvpx libwebp libwebp-tools libxcomposite \\
    libxt mesa-gl mesa-dri-gallium nspr nss pipewire-libs libpulse \\
    ttf-freefont xvfb xvfb-run jq \\
    ffmpeg-libs
COPY --from=chromium-fetch /opt/chromium-bundle /opt/chromium-bundle
COPY --from=${IMAGE_REF} /firefox /ms-playwright/firefox-${ARTIFACT_REV}/firefox
RUN touch /ms-playwright/firefox-${ARTIFACT_REV}/INSTALLATION_COMPLETE
# musl Juggler workaround, applied at the BINARY (not via PW args): the FF Juggler
# stays dormant unless launched with --remote-debugging-port=0 (wakes RemoteAgent).
# The conformance config injects that arg, but PW's PlaywrightServer.filterLaunchOptions
# STRIPS all client-supplied `args` for RCE-prevention on the `run-server` path, so
# browsertype-connect run-server tests launch FF without it → 38min hang. Wrap the
# binary so the arg is always present regardless of PW's filtering — the security
# filter stays fully intact. Dedup guard avoids double-passing on paths that add it.
RUN FFBIN=/ms-playwright/firefox-${ARTIFACT_REV}/firefox/firefox \\
 && mv "\$FFBIN" "\$FFBIN.real" \\
 && printf '%s\\n' \\
      '#!/bin/sh' \\
      'D=\$(dirname "\$0")' \\
      'case " \$* " in' \\
      '  *" --remote-debugging-port"*) exec "\$D/firefox.real" "\$@" ;;' \\
      '  *) exec "\$D/firefox.real" --remote-debugging-port=0 "\$@" ;;' \\
      'esac' \\
      > "\$FFBIN" \\
 && chmod +x "\$FFBIN"
# PW SDK prefs — Alpine FF build (apply-and-build.sh:175) writes these to the
# wrong path (browser/app/profile/); Ubuntu FF ships them at these exact
# locations. Missing them means `dom.security.https_first` stays true, PW's
# proxy filter never attaches, and every proxy / client-cert test fails.
# Root cause diagnosed 2026-07-09; drop-in fetch here recovers ~56 tests
# (client-certs + proxy.spec.ts + siblings) without rebuilding FF.
#
# 01-alpine-pointer.js: headless musl FF's LookAndFeel defaults pointer/hover to
# coarse/none, so `(hover: hover)` + `(pointer: fine)` don't match on the default
# desktop context (page-emulate-media "should report hover and fine pointer for
# desktop" fails). Ubuntu FF reports fine+hover by default; PW forces it for
# chromium via --blink-settings but has no firefox equivalent. Force it via FF's
# own pref (6 = eFine|eHover). Diagnosed + validated locally 2026-07-21; also
# baked into the artifact in apply-and-build.sh so consumers get the same default.
RUN apk add --no-cache curl \\
 && mkdir -p /ms-playwright/firefox-${ARTIFACT_REV}/firefox/browser/defaults/preferences \\
 && curl -fsSL "https://raw.githubusercontent.com/microsoft/playwright/v${PW_VERSION}/browser_patches/firefox/preferences/00-playwright-prefs.js" \\
      -o /ms-playwright/firefox-${ARTIFACT_REV}/firefox/browser/defaults/preferences/00-playwright-prefs.js \\
 && curl -fsSL "https://raw.githubusercontent.com/microsoft/playwright/v${PW_VERSION}/browser_patches/firefox/preferences/playwright.cfg" \\
      -o /ms-playwright/firefox-${ARTIFACT_REV}/firefox/playwright.cfg \\
 && printf 'pref("ui.primaryPointerCapabilities", 6);\\npref("ui.allPointerCapabilities", 6);\\n' \\
      > /ms-playwright/firefox-${ARTIFACT_REV}/firefox/browser/defaults/preferences/01-alpine-pointer.js
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \\
    LD_LIBRARY_PATH=/ms-playwright/firefox-${ARTIFACT_REV}/firefox
RUN npm install -g playwright@${PW_VERSION}
RUN playwright install ffmpeg
# Place chromium at PW's auto-discovery path so recorder-UI (\_enableRecorder)
# finds a musl-native chromium instead of throwing 'No chromium-based browser
# found'. Revision is looked up from playwright-core/browsers.json rather than
# hard-coded so it stays in sync with the installed PW.
RUN PWC_JSON=\$(find /usr/local/lib/node_modules -name browsers.json -path '*playwright-core*' | head -1) \\
 && CHR_REV=\$(jq -r '.browsers[] | select(.name == "chromium") | .revision' "\$PWC_JSON") \\
 && CHS_REV=\$(jq -r '.browsers[] | select(.name == "chromium-headless-shell") | .revision' "\$PWC_JSON") \\
 && CHR_DIR=/ms-playwright/chromium-\${CHR_REV}/chrome-linux64 \\
 && CHS_DIR=/ms-playwright/chromium_headless_shell-\${CHS_REV}/chrome-headless-shell-linux64 \\
 && mkdir -p "\${CHR_DIR}" "\${CHS_DIR}" \\
 && cp -a /opt/chromium-bundle/* "\${CHR_DIR}"/ \\
 && cp -a /opt/chromium-bundle/* "\${CHS_DIR}"/ \\
 && ln -sf chrome "\${CHS_DIR}"/chrome-headless-shell \\
 && touch /ms-playwright/chromium-\${CHR_REV}/INSTALLATION_COMPLETE \\
 && touch /ms-playwright/chromium_headless_shell-\${CHS_REV}/INSTALLATION_COMPLETE \\
 && "\${CHR_DIR}"/chrome --version
EOF
    ;;

  webkit)
    # Runtime apk list + path layout mirror smoke-webkit (Tier-2) since
    # PW SDK launches MiniBrowser-wpe the same way for both. Without the
    # GStreamer + mesa + WPE deps, WPEWebProcess crashes at +14s during
    # page creation. PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1 works
    # around the upstream PW musl-ldconfig false-positive (musl rejects
    # /sbin/ldconfig -p so PW thinks libGLESv2/libx264 are missing).
    # `/webkit` artifact maps directly to `webkit-${REV}/` (no nested
    # subdir) and contains `pw_run.sh` + `minibrowser-{wpe,gtk}/`.
    #
    # 2026-07-15: chromium re-added via multi-stage self-contained bundle at
    # /opt/chromium-bundle/ (isolated from :edge system libs via RPATH
    # \$ORIGIN). Recorder-UI subsystem needs a HEADED chromium binary. Bundle
    # base :3.22 (chromium 142); :3.23/149 trace-viewer probe reverted — see
    # FF branch comment.
    cat > "$TMPDIR/Dockerfile" <<EOF
FROM alpine:3.22 AS chromium-fetch
RUN apk add --no-cache chromium chromium-swiftshader binutils patchelf
RUN mkdir -p /opt/chromium-bundle \\
 && SRC=/usr/lib/chromium && DEST=/opt/chromium-bundle \\
 && cp -aL "\$SRC"/* "\$DEST"/ \\
 && mv "\$DEST"/chromium "\$DEST"/chrome \\
 && for so in \$(ldd "\$DEST"/chrome 2>/dev/null | awk '{print \$3}' | grep '^/'); do \\
      [ -f "\$so" ] && [ ! -f "\$DEST/\$(basename "\$so")" ] && cp -aL "\$so" "\$DEST"/ || true; \\
    done \\
 && for bin in "\$DEST"/chrome_crashpad_handler "\$DEST"/chrome-sandbox; do \\
      [ -f "\$bin" ] || continue; \\
      for so in \$(ldd "\$bin" 2>/dev/null | awk '{print \$3}' | grep '^/'); do \\
        [ -f "\$so" ] && [ ! -f "\$DEST/\$(basename "\$so")" ] && cp -aL "\$so" "\$DEST"/ || true; \\
      done; \\
    done \\
 && for lib in "\$DEST"/*.so*; do \\
      [ -L "\$lib" ] && continue; \\
      for so in \$(ldd "\$lib" 2>/dev/null | awk '{print \$3}' | grep '^/'); do \\
        [ -f "\$so" ] && [ ! -f "\$DEST/\$(basename "\$so")" ] && cp -aL "\$so" "\$DEST"/ || true; \\
      done; \\
    done \\
 && for so in libsoftokn3.so libfreebl3.so libnssdbm3.so libnssckbi.so libnsspem.so libsqlite3.so.0 libplc4.so libplds4.so; do \\
      [ -f "/usr/lib/\$so" ] && [ ! -f "\$DEST/\$so" ] && cp -aL "/usr/lib/\$so" "\$DEST"/ || true; \\
    done \\
 && patchelf --set-rpath '\$ORIGIN' "\$DEST"/chrome \\
 && for bin in "\$DEST"/chrome_crashpad_handler "\$DEST"/chrome-sandbox; do \\
      [ -f "\$bin" ] && patchelf --set-rpath '\$ORIGIN' "\$bin" 2>/dev/null || true; \\
    done \\
 && for so in "\$DEST"/*.so*; do [ -L "\$so" ] && continue; patchelf --set-rpath '\$ORIGIN' "\$so" 2>/dev/null || true; done \\
 && "\$DEST"/chrome --version

FROM alpine:edge AS webrtc-build
# WebRTC runtime plugin: Alpine's gst-plugins-bad OMITS the classic 'webrtc'
# plugin (webrtcbin) — gst 1.28 needs libnice >= 0.1.23 (NICE_AGENT_OPTION_CLOSE_
# FORCED) but Alpine ships 0.1.22. WebKit's GStreamerWebRTCProvider checks the
# 'webrtc' plugin is registered + eagerly creates webrtcbin at RTCPeerConnection
# construction; without it new RTCPeerConnection() throws → Modernizr
# datachannel:false. Build libnice 0.1.23 + the webrtc plugin from source against
# the runner's own gstreamer. GSTVER auto-detected so it can't drift from edge.
RUN apk add --no-cache build-base meson ninja pkgconf curl \\
    gstreamer-dev gst-plugins-base-dev gst-plugins-bad-dev openssl-dev libsrtp-dev glib-dev
RUN set -e; GSTVER=\$(pkg-config --modversion gstreamer-1.0); cd /tmp \\
 && curl -fsSL "https://gitlab.freedesktop.org/libnice/libnice/-/archive/0.1.23/libnice-0.1.23.tar.gz" | tar xz \\
 && cd libnice-0.1.23 \\
 && meson setup b --prefix=/usr --libdir=lib -Dgstreamer=enabled \\
      -Dtests=disabled -Dexamples=disabled -Dintrospection=disabled -Dgtk_doc=disabled \\
 && ninja -C b install \\
 && cd /tmp \\
 && curl -fsSL "https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-\${GSTVER}.tar.xz" | tar xJ \\
 && cd gst-plugins-bad-\${GSTVER} \\
 && meson setup build -Dauto_features=disabled \\
      -Dwebrtc=enabled -Dsctp=enabled -Ddtls=enabled -Dsrtp=enabled \\
      -Dnls=disabled -Dorc=disabled -Dgpl=disabled \\
      -Dexamples=disabled -Dtests=disabled -Dintrospection=disabled -Ddoc=disabled \\
 && ninja -C build ext/webrtc/libgstwebrtc.so \\
 && mkdir -p /webrtc-dist/gstreamer-1.0 \\
 && cp build/ext/webrtc/libgstwebrtc.so                          /webrtc-dist/gstreamer-1.0/ \\
 && cp -a /usr/lib/gstreamer-1.0/libgstnice.so                   /webrtc-dist/gstreamer-1.0/ \\
 && cp -a build/gst-libs/gst/webrtc/nice/libgstwebrtcnice-1.0.so* /webrtc-dist/ \\
 && cp -a /usr/lib/libnice.so.10*                                /webrtc-dist/

FROM alpine:edge
RUN apk update && apk add --no-cache \\
    nodejs npm bash git \\
    file binutils ca-certificates ttf-freefont \\
    libwpe libwpebackend-fdo \\
    gtk4.0 at-spi2-core \\
    libgcc libstdc++ \\
    mesa-gles mesa-gbm mesa-dri-gallium mesa-vulkan-swrast \\
    gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-libav \\
    gst-plugins-ugly openh264 \\
    cairo pango gdk-pixbuf libnotify dbus-libs opus libsecret \\
    nss icu-data-full \\
    xvfb xvfb-run jq \\
    font-noto-emoji font-liberation
# WebRTC runtime: our libnice 0.1.23 + the built 'webrtc' plugin (webrtcbin) +
# updated nice element. gst-plugins-bad (above) ships the dtls/srtp/sctp plugins +
# libgstwebrtc-1.0 the plugin links; GST_PLUGIN_SYSTEM_PATH_1_0 (set below) points
# at /usr/lib/gstreamer-1.0 so webrtcbin is auto-discovered. font-noto-emoji fixes
# Modernizr's emoji canvas-pixel key. font-liberation makes `local("Arial")`
# resolve (fontconfig aliases Arial→Liberation Sans) — Modernizr's unicoderange
# test declares `@font-face{src:local("Arial");unicode-range:U+0020,U+002E}` and
# reports false when Arial is absent; adding Liberation flips unicoderange true
# (validated locally 2026-07-21 → modernizr Safari Desktop passes). Last modernizr key.
COPY --from=webrtc-build /webrtc-dist/libnice.so.10*             /usr/lib/
COPY --from=webrtc-build /webrtc-dist/libgstwebrtcnice-1.0.so*   /usr/lib/
COPY --from=webrtc-build /webrtc-dist/gstreamer-1.0/             /usr/lib/gstreamer-1.0/
COPY --from=chromium-fetch /opt/chromium-bundle /opt/chromium-bundle
COPY --from=${IMAGE_REF} /webkit /ms-playwright/webkit-${ARTIFACT_REV}
RUN touch /ms-playwright/webkit-${ARTIFACT_REV}/INSTALLATION_COMPLETE
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
# WebKit's WebProcess builds an EMPTY GStreamer registry unless pointed at the
# apk plugin dir + scanner — canPlayType() then returns '' for every codec.
# Point it at the runner's gstreamer-1.0 install so media capability + playback
# discover the avdec/vpx/opus decoders.
ENV GST_PLUGIN_SYSTEM_PATH_1_0=/usr/lib/gstreamer-1.0
ENV GST_PLUGIN_SCANNER_1_0=/usr/libexec/gstreamer-1.0/gst-plugin-scanner
ENV GST_REGISTRY_1_0=/tmp/gst-registry.bin
RUN npm install -g playwright@${PW_VERSION}
# ffmpeg-1011 needed by recordVideo + screencast fixtures; skip-list narrows the
# affected suite, but downloading lets the rest of tests/library boot cleanly.
RUN playwright install ffmpeg
# Same recorder-UI setup as FF runner — musl chromium at PW's auto-discovery
# path so \_enableRecorder finds it.
RUN PWC_JSON=\$(find /usr/local/lib/node_modules -name browsers.json -path '*playwright-core*' | head -1) \\
 && CHR_REV=\$(jq -r '.browsers[] | select(.name == "chromium") | .revision' "\$PWC_JSON") \\
 && CHS_REV=\$(jq -r '.browsers[] | select(.name == "chromium-headless-shell") | .revision' "\$PWC_JSON") \\
 && CHR_DIR=/ms-playwright/chromium-\${CHR_REV}/chrome-linux64 \\
 && CHS_DIR=/ms-playwright/chromium_headless_shell-\${CHS_REV}/chrome-headless-shell-linux64 \\
 && mkdir -p "\${CHR_DIR}" "\${CHS_DIR}" \\
 && cp -a /opt/chromium-bundle/* "\${CHR_DIR}"/ \\
 && cp -a /opt/chromium-bundle/* "\${CHS_DIR}"/ \\
 && ln -sf chrome "\${CHS_DIR}"/chrome-headless-shell \\
 && touch /ms-playwright/chromium-\${CHR_REV}/INSTALLATION_COMPLETE \\
 && touch /ms-playwright/chromium_headless_shell-\${CHS_REV}/INSTALLATION_COMPLETE \\
 && "\${CHR_DIR}"/chrome --version
EOF
    ;;

  *)
    echo "Unsupported BROWSER: $BROWSER" >&2; exit 1 ;;
esac

echo "==== Building $IMAGE_TAG_OUT from $TMPDIR/Dockerfile ===="
docker build -t "$IMAGE_TAG_OUT" -f "$TMPDIR/Dockerfile" "$TMPDIR"
