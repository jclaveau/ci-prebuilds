#!/usr/bin/env bash
# Consumer-side dedup of universal runtime libs from bundled Firefox/WebKit
# artifacts.
#
# bundle-dist.sh walks DT_NEEDED and bundles glib/gtk3/cairo (Firefox) and
# glib/soup/gstreamer/sqlite (WebKit) into the self-contained artifact. Consumer
# images whose base already installs those via apk (the combined dind/dood
# image + the conformance runner) carry pure duplication: the bundle's
# RPATH=$ORIGIN resolution falls back to /usr/lib for anything it no longer
# carries, so the apk build (a fresh edge snapshot, newer than the build-time
# one) satisfies every dep. Measured savings: firefox 342→306 MB, webkit
# 760→483 MB (webkit incl. strip-mesa-closure.sh's ~225 MB), plus ~5.7 MB more
# from the cross-bundle ICU dedup below.
#
# The producer artifacts stay intact (FROM scratch, no apk to fall back to) —
# this script is applied to the COPY'd bundles on the consumer side, after the
# apk install.
#
# Every lib with an apk twin is stripped — including NSS/nspr (Firefox Juggler),
# codecs (libglycin for FF, libaom/libdav1d/libjxl/libyuv for WebKit), WPE core
# (libwpe/libWPEBackend-fdo) and libcrypto/libgstwebrtc. The apk soname major
# matches the edge build-time one (verified per-family before enabling);
# behavioral parity is covered by the conformance runner, which applies the SAME
# strip so the tested layout == the shipped layout.
#
# Exception: libvpx stays bundled. It was enabled briefly but Firefox's libxul
# needs the mozilla-built vpx symbol set, which the alpine:edge libvpx apk does
# not export (22 unresolved symbols at launch) while alpine 3.24's does — so the
# conformance runner (edge-based) can't validate a vpx-stripped layout, and
# shipping one would leave it unvalidated. ~7 MB stays duplicated instead.
#
# ICU stays bundled for the opposite reason: the apk soname matches (icu-libs
# ships .so.78 on both edge and 3.24) but the 3.24 consumer installs only the
# English-only icu-data-en set — full coverage would need icu-data-full
# (+31.6 MB), a net loss against the ~11.4 MB stripping both bundles saves.
# Firefox additionally ships its own icudt78l.dat. Both bundles carry
# byte-identical ICU 78, so the combined image hardlinks webkit's libicu* to
# firefox's (3rd arg below) — one copy, ~5.7 MB saved. The per-browser
# conformance runners keep real copies (each image runs a single bundle); the
# loader loads the same inode either way, so tested == shipped holds by
# byte-equality.
#
# Exclusion policy — these stay bundled:
#   - the browser's OWN libs (libxul, libmoz*, libgkcodecs, libclearkey,
#     libWPEWebKit, libWPEInjectedBundle): no apk equivalent
#   - libs the apk base does NOT provide (flite*, libavif, libhyphen,
#     libwoff2*, libatomic, libharfbuzz-icu): no /usr/lib fallback
#
# Usage: strip-bundled-libs.sh <bundle_dir> firefox|webkit [<dedup_src_dir>]
#   - <dedup_src_dir> (webkit only): hardlink webkit's still-bundled libs that
#     are byte-identical in the source bundle (currently the ICU triplet) to
#     the source dir's copies, dropping the duplicate. md5-gated: a skew
#     between the bundles' versions skips that lib with a warning instead of
#     silently switching webkit onto firefox's build.
# Idempotent (no-op when the libs are absent). Fails if any remaining ELF still
# has unresolved deps — a removed lib the apk doesn't provide surfaces here
# instead of at browser launch.

set -euo pipefail

DST="${1:?usage: strip-bundled-libs.sh <bundle_dir> firefox|webkit [<dedup_src_dir>]}"
FAMILY="${2:?usage: strip-bundled-libs.sh <bundle_dir> firefox|webkit [<dedup_src_dir>]}"
DEDUP_SRC="${3:-}"
[ -d "$DST" ] || { echo "strip-bundled-libs: $DST is not a directory" >&2; exit 1; }
case "$FAMILY" in
  firefox|webkit) ;;
  *) echo "strip-bundled-libs: unknown family '$FAMILY'" >&2; exit 1;;
esac
if [ -n "$DEDUP_SRC" ]; then
  [ "$FAMILY" = webkit ] || { echo "strip-bundled-libs: <dedup_src_dir> only applies to webkit" >&2; exit 1; }
  [ -d "$DEDUP_SRC" ] || { echo "strip-bundled-libs: dedup src '$DEDUP_SRC' is not a directory" >&2; exit 1; }
fi

# Universal runtime libs present in BOTH bundles and provided by the consumer's
# apk base. Sonames are apk-stable (glib/gtk/gstreamer keep their major).
STRIP_COMMON="
libasound.so.2
libatk-1.0.so.0
libatk-bridge-2.0.so.0
libatspi.so.0
libblkid.so.1
libbrotlicommon.so.1
libbrotlidec.so.1
libbsd.so.0
libbz2.so.1
libdbus-1.so.3
libeconf.so.0
libepoxy.so.0
libexpat.so.1
libffi.so.8
libfontconfig.so.1
libfreetype.so.6
libgio-2.0.so.0
libglib-2.0.so.0
libgmodule-2.0.so.0
libgobject-2.0.so.0
libgraphite2.so.3
libharfbuzz.so.0
libintl.so.8
libjpeg.so.8
liblcms2.so.2
libmd.so.0
libmount.so.1
libpcre2-8.so.0
libpng16.so.16
libseccomp.so.2
libsharpyuv.so.0
libwayland-client.so.0
libwayland-cursor.so.0
libwayland-egl.so.1
libwebp.so.7
libwebpdemux.so.2
libxkbcommon.so.0
libz.so.1
"

# Firefox-only additions: the gtk3 widget stack + cairo/pango/X11 closure, plus
# NSS/nspr (Juggler TLS + crypto) and the glycin codec the apk ships. libvpx
# is NOT here — see the header exception.
STRIP_FIREFOX="
libX11-xcb.so.1
libX11.so.6
libXau.so.6
libXcomposite.so.1
libXcursor.so.1
libXdamage.so.1
libXdmcp.so.6
libXext.so.6
libXfixes.so.3
libXi.so.6
libXinerama.so.1
libXrandr.so.2
libXrender.so.1
libcairo-gobject.so.2
libcairo.so.2
libevent-2.1.so.7
libfribidi.so.0
libgdk-3.so.0
libgdk_pixbuf-2.0.so.0
libglycin-2.so.0
libgtk-3.so.0
libnspr4.so
libnss3.so
libnssutil3.so
libpango-1.0.so.0
libpangocairo-1.0.so.0
libpangoft2-1.0.so.0
libpixman-1.so.0
libplc4.so
libplds4.so
libsmime3.so
libssl3.so
libxcb-render.so.0
libxcb-shm.so.0
libxcb.so.1
"

# WebKit-only additions: gstreamer core + soup/sqlite/xml network stack, the
# image/codec decoders the apk provides (aom/dav1d/jxl/yuv), WPE core and
# libcrypto (soup/TLS) + the gstreamer webrtc lib.
STRIP_WEBKIT="
libWPEBackend-fdo-1.0.so.1
libaom.so.3
libbrotlienc.so.1
libcrypto.so.3
libdav1d.so.7
libgcrypt.so.20
libgpg-error.so.0
libgstallocators-1.0.so.0
libgstapp-1.0.so.0
libgstaudio-1.0.so.0
libgstbase-1.0.so.0
libgstfft-1.0.so.0
libgstgl-1.0.so.0
libgstpbutils-1.0.so.0
libgstreamer-1.0.so.0
libgstrtp-1.0.so.0
libgstsdp-1.0.so.0
libgsttag-1.0.so.0
libgstvideo-1.0.so.0
libgstwebrtc-1.0.so.0
libhwy.so.1
libidn2.so.0
libjxl.so.0.11
libjxl_cms.so.0.11
liblzma.so.5
libnghttp2.so.14
liborc-0.4.so.0
libpciaccess.so.0
libpsl.so.5
libsoup-3.0.so.0
libsqlite3.so.0
libtasn1.so.6
libunistring.so.5
libwayland-server.so.0
libwebpmux.so.3
libwpe-1.0.so.1
libxml2.so.2
libxslt.so.1
libyuv.so
libzstd.so.1
"

case "$FAMILY" in
  firefox) STRIP_LIST="$STRIP_COMMON $STRIP_FIREFOX";;
  webkit) STRIP_LIST="$STRIP_COMMON $STRIP_WEBKIT";;
esac

removed=0
for f in $STRIP_LIST; do
  if [ -f "$DST/$f" ]; then
    rm -f "$DST/$f"
    removed=$((removed + 1))
  fi
done
echo "strip-bundled-libs: removed $removed bundled libs from $(basename "$DST") ($FAMILY)"

# Cross-bundle dedup (combined image only): hardlink webkit's still-bundled
# libs that the other bundle carries byte-identical (ICU 78 today) to the
# source dir's copy. Same filesystem, so one inode serves both bundles.
# md5-gated so a version skew between the two bundles keeps webkit's own copy.
dedup=0
if [ -n "$DEDUP_SRC" ]; then
  for f in "$DST"/*.so*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    [ -f "$DEDUP_SRC/$base" ] || continue
    [ "$(md5sum "$f" | cut -d' ' -f1)" = "$(md5sum "$DEDUP_SRC/$base" | cut -d' ' -f1)" ] || {
      echo "  WARN: $base differs between bundles — keeping $(basename "$DST")'s own copy" >&2
      continue
    }
    rm -f "$f"
    ln "$DEDUP_SRC/$base" "$f"
    dedup=$((dedup + 1))
  done
  echo "strip-bundled-libs: hardlinked $dedup identical lib(s) from $(basename "$DST") to $(basename "$DEDUP_SRC")"
fi

# Gate: every remaining ELF in the bundle must resolve against the consumer's
# libs (RPATH=$ORIGIN + default /usr/lib, where the apk runtime now lives) —
# mirrors bundle-dist.sh's own post-bundle check. Recursive: stripped libs may
# sit under subdirectories (e.g. firefox's browser/components).
missing=0
while IFS= read -r -d '' f; do
  [ "$(od -An -N4 -tx1 "$f" 2>/dev/null | tr -d ' \n')" = "7f454c46" ] || continue
  notfound=$(ldd "$f" 2>&1 | grep -c 'not found' || true)
  if [ "$notfound" -gt 0 ]; then
    echo "ERROR: ${f#$DST/} has $notfound unresolved deps after strip:" >&2
    ldd "$f" 2>&1 | grep 'not found' >&2
    missing=$((missing + notfound))
  fi
done < <(find "$DST" -type f -print0)
[ "$missing" -eq 0 ] || { echo "strip-bundled-libs: FAILED with $missing unresolved dep(s)" >&2; exit 1; }
echo "strip-bundled-libs: all remaining ELFs resolve against consumer libs"
