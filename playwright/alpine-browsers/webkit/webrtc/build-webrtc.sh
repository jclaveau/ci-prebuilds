#!/bin/sh
# Builds GStreamer's `webrtc` plugin (webrtcbin) and the libnice 0.1.23 it
# needs, and stages the runtime files under $1 (default /webrtc-dist):
#   $1/libnice.so.10*                    our libnice, over Alpine's 0.1.22
#   $1/libgstwebrtcnice-1.0.so*          the plugin's nice transport library
#   $1/gstreamer-1.0/libgstwebrtc.so     webrtcbin
#   $1/gstreamer-1.0/libgstnice.so       nicesrc/nicesink against our libnice
# The caller COPYs $1 into /usr/lib, from a build stage, so none of the
# toolchain this installs reaches the runtime image.
#
# Alpine's gst-plugins-bad omits the plugin: gst 1.28 needs libnice >= 0.1.23
# (NICE_AGENT_OPTION_CLOSE_FORCED) and Alpine ships 0.1.22. WebKit's
# GStreamerWebRTCProvider checks the plugin is registered and creates a
# webrtcbin when an RTCPeerConnection is constructed, so without it
# `new RTCPeerConnection()` throws "InvalidAccessError: Bad Configuration
# Parameters" (webrtc-shipped-probe.yml, alpine webkit, 2026-11-17).
#
# Run as root (the consumer image calls it under sudo, the conformance runner
# is already root), on the same alpine the runtime image uses: GSTVER is read
# from the installed gstreamer, so the plugin matches the libs it loads into.
#
# TWO callers must stay in step, which is why this is a script and not an
# inline RUN: playwright/Dockerfile.alpine builds the image we ship, and
# playwright/alpine-browsers/conformance/build-runner.sh builds the image
# conformance tests. Until 2026-11-17 only the runner built it, so
# conformance-webkit passed modernizr's peerconnection/datachannel keys on a
# browser whose shipped copy threw on the constructor.
set -eu

DIST="${1:-/webrtc-dist}"
LIBNICE_VERSION=0.1.23

apk add --no-cache build-base meson ninja pkgconf curl \
  gstreamer-dev gst-plugins-base-dev gst-plugins-bad-dev openssl-dev libsrtp-dev glib-dev

GSTVER=$(pkg-config --modversion gstreamer-1.0)
# "3.24.1" -> "v3.24": the distfiles directory of the release this runs on.
ALPINE_BRANCH="v$(cut -d. -f1,2 /etc/alpine-release)"
cd /tmp

# Every archive is fetched to a FILE and integrity-checked before it is
# extracted. `curl | tar` cannot fall back: on 2026-08-24 the primary failed
# mid-stream (PROTOCOL_ERROR after the headers), -f could not suppress the
# partial body, and tar left a half-extracted tree that still had
# ext/webrtc. Busybox tar also accepts an empty body without complaint, so a
# dropped libnice fetch surfaced later as `Dependency "nice" not found` (run
# 34124287051 shard 4), reading as a recipe fault.
attempt=1
until curl -fsSL --retry 3 --retry-all-errors -o nice.tar.gz \
    "https://gitlab.freedesktop.org/libnice/libnice/-/archive/${LIBNICE_VERSION}/libnice-${LIBNICE_VERSION}.tar.gz" \
    && gzip -t nice.tar.gz; do
  [ "$attempt" -lt 5 ] || { echo "libnice fetch failed 5 times" >&2; exit 1; }
  echo "libnice fetch attempt $attempt failed; retrying" >&2
  sleep $((attempt * 5))
  attempt=$((attempt + 1))
done
tar xzf nice.tar.gz && rm nice.tar.gz
meson setup "libnice-${LIBNICE_VERSION}/b" "libnice-${LIBNICE_VERSION}" \
  --prefix=/usr --libdir=lib -Dgstreamer=enabled \
  -Dtests=disabled -Dexamples=disabled -Dintrospection=disabled -Dgtk_doc=disabled
ninja -C "libnice-${LIBNICE_VERSION}/b" install
pkg-config --atleast-version="$LIBNICE_VERSION" nice

# Two sources: gstreamer.freedesktop.org 503'd for hours on 2026-08-24 and took
# 19 of 20 webkit conformance shards with it. Alpine's distfiles cache holds
# the right version by construction: GSTVER is what this alpine packages, and
# distfiles keeps the tarball of exactly the version it packages. libnice has
# no such fallback: we build a newer one than Alpine packages.
{ curl -fsSL -o gpb.tar.xz "https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-${GSTVER}.tar.xz" \
    && xz -t gpb.tar.xz; } \
  || { curl -fsSL -o gpb.tar.xz "https://distfiles.alpinelinux.org/distfiles/${ALPINE_BRANCH}/gst-plugins-bad-${GSTVER}.tar.xz" \
    && xz -t gpb.tar.xz; }
tar xJf gpb.tar.xz && rm gpb.tar.xz
cd "gst-plugins-bad-${GSTVER}"
meson setup build -Dauto_features=disabled \
  -Dwebrtc=enabled -Dsctp=enabled -Ddtls=enabled -Dsrtp=enabled \
  -Dnls=disabled -Dorc=disabled -Dgpl=disabled \
  -Dexamples=disabled -Dtests=disabled -Dintrospection=disabled -Ddoc=disabled
ninja -C build ext/webrtc/libgstwebrtc.so

mkdir -p "$DIST/gstreamer-1.0"
cp build/ext/webrtc/libgstwebrtc.so "$DIST/gstreamer-1.0/"
cp -a /usr/lib/gstreamer-1.0/libgstnice.so "$DIST/gstreamer-1.0/"
cp -a build/gst-libs/gst/webrtc/nice/libgstwebrtcnice-1.0.so* "$DIST/"
cp -a /usr/lib/libnice.so.10* "$DIST/"
