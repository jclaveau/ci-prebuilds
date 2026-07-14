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
    # Trade-off: alpine :edge's chromium apk is broken (still declares
    # dep on libFLAC.so.12 post-flac-1.5). Drop `chromium xvfb-run` from
    # the FF runner — all recorder-UI codegen/inspector/trace-viewer/
    # slowmo tests are already file-skipped in the FF skip-list, so the
    # loss is zero-cost. Xvfb is bundled in `xvfb` package.
    cat > "$TMPDIR/Dockerfile" <<EOF
FROM alpine:edge
RUN apk update && apk add --no-cache \\
    nodejs npm bash git build-base python3 \\
    alsa-lib dbus-libs fontconfig freetype glib gtk+3.0 harfbuzz \\
    icu-libs libevent libffi libjpeg-turbo libnotify libogg \\
    libtheora libvorbis libvpx libwebp libwebp-tools libxcomposite \\
    libxt mesa-gl mesa-dri-gallium nspr nss pipewire-libs libpulse \\
    ttf-freefont xvfb xvfb-run
COPY --from=${IMAGE_REF} /firefox /ms-playwright/firefox-${ARTIFACT_REV}/firefox
RUN touch /ms-playwright/firefox-${ARTIFACT_REV}/INSTALLATION_COMPLETE
# PW SDK prefs — Alpine FF build (apply-and-build.sh:175) writes these to the
# wrong path (browser/app/profile/); Ubuntu FF ships them at these exact
# locations. Missing them means `dom.security.https_first` stays true, PW's
# proxy filter never attaches, and every proxy / client-cert test fails.
# Root cause diagnosed 2026-07-09; drop-in fetch here recovers ~56 tests
# (client-certs + proxy.spec.ts + siblings) without rebuilding FF.
RUN apk add --no-cache curl \\
 && mkdir -p /ms-playwright/firefox-${ARTIFACT_REV}/firefox/browser/defaults/preferences \\
 && curl -fsSL "https://raw.githubusercontent.com/microsoft/playwright/v${PW_VERSION}/browser_patches/firefox/preferences/00-playwright-prefs.js" \\
      -o /ms-playwright/firefox-${ARTIFACT_REV}/firefox/browser/defaults/preferences/00-playwright-prefs.js \\
 && curl -fsSL "https://raw.githubusercontent.com/microsoft/playwright/v${PW_VERSION}/browser_patches/firefox/preferences/playwright.cfg" \\
      -o /ms-playwright/firefox-${ARTIFACT_REV}/firefox/playwright.cfg
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \\
    LD_LIBRARY_PATH=/ms-playwright/firefox-${ARTIFACT_REV}/firefox
RUN npm install -g playwright@${PW_VERSION}
RUN playwright install ffmpeg
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
    # WebKit runner MUST match alpine:edge (WebKit built on edge). Same
    # SONAME rationale as FF above. Drop `chromium` — alpine :edge chromium
    # apk broken post-flac-1.5, and WebKit's recorder-UI tests are already
    # file-skipped in webkit skip-list.
    cat > "$TMPDIR/Dockerfile" <<EOF
FROM alpine:edge
RUN apk update && apk add --no-cache \\
    nodejs npm bash git \\
    file binutils ca-certificates ttf-freefont \\
    libwpe libwpebackend-fdo \\
    gtk4.0 at-spi2-core \\
    libgcc libstdc++ \\
    mesa-gles mesa-gbm mesa-dri-gallium mesa-vulkan-swrast \\
    gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-libav \\
    cairo pango gdk-pixbuf libnotify dbus-libs opus libsecret \\
    xvfb xvfb-run
COPY --from=${IMAGE_REF} /webkit /ms-playwright/webkit-${ARTIFACT_REV}
RUN touch /ms-playwright/webkit-${ARTIFACT_REV}/INSTALLATION_COMPLETE
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
RUN npm install -g playwright@${PW_VERSION}
# ffmpeg-1011 needed by recordVideo + screencast fixtures; skip-list narrows the
# affected suite, but downloading lets the rest of tests/library boot cleanly.
RUN playwright install ffmpeg
EOF
    ;;

  *)
    echo "Unsupported BROWSER: $BROWSER" >&2; exit 1 ;;
esac

echo "==== Building $IMAGE_TAG_OUT from $TMPDIR/Dockerfile ===="
docker build -t "$IMAGE_TAG_OUT" -f "$TMPDIR/Dockerfile" "$TMPDIR"
