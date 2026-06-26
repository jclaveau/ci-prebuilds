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
    cat > "$TMPDIR/Dockerfile" <<EOF
FROM alpine:edge
RUN apk update && apk add --no-cache \\
    nodejs npm bash git \\
    ca-certificates font-opensans ttf-freefont
COPY --from=${IMAGE_REF} \\
     /chrome-headless-shell-linux64 \\
     /ms-playwright/chromium_headless_shell-${ARTIFACT_REV}/chrome-headless-shell-linux64
RUN touch /ms-playwright/chromium_headless_shell-${ARTIFACT_REV}/INSTALLATION_COMPLETE
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g playwright@${PW_VERSION}
EOF
    ;;

  firefox)
    cat > "$TMPDIR/Dockerfile" <<EOF
FROM alpine:edge
RUN apk update && apk add --no-cache \\
    nodejs npm bash git build-base python3 \\
    alsa-lib dbus-libs fontconfig freetype glib gtk+3.0 harfbuzz \\
    icu-libs libevent libffi libjpeg-turbo libnotify libogg \\
    libtheora libvorbis libvpx libwebp libwebp-tools libxcomposite \\
    libxt mesa-gl mesa-dri-gallium nspr nss pipewire-libs libpulse \\
    ttf-freefont
COPY --from=${IMAGE_REF} /firefox /ms-playwright/firefox-${ARTIFACT_REV}/firefox
RUN touch /ms-playwright/firefox-${ARTIFACT_REV}/INSTALLATION_COMPLETE
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \\
    LD_LIBRARY_PATH=/ms-playwright/firefox-${ARTIFACT_REV}/firefox
RUN npm install -g playwright@${PW_VERSION}
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
EOF
    ;;

  *)
    echo "Unsupported BROWSER: $BROWSER" >&2; exit 1 ;;
esac

echo "==== Building $IMAGE_TAG_OUT from $TMPDIR/Dockerfile ===="
docker build -t "$IMAGE_TAG_OUT" -f "$TMPDIR/Dockerfile" "$TMPDIR"
