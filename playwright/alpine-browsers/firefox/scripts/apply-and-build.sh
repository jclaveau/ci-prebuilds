#!/usr/bin/env bash
# Orchestrate: fetch Firefox source tarball, apply aports' musl patches, apply
# PW's Juggler + bootstrap, build with mozconfig overlay, copy artifact out.
#
# Usage: apply-and-build.sh <work_dir>
# Expects: <work_dir>/aports/    (from fetch-aports.sh)
#          <work_dir>/pw-firefox/ (from fetch-pw-patches.sh)
#          <work_dir>/firefox/mozconfig.overlay (our overlay, copied in)
# Writes:  <work_dir>/firefox-src/obj-*/dist/firefox/   (the built browser)

set -euo pipefail

WORK="${1:?usage: apply-and-build.sh <work_dir>}"
APORTS="$WORK/aports"
PW="$WORK/pw-firefox"
OVERLAY="$WORK/firefox/mozconfig.overlay"
SRC="$WORK/firefox-src"

[[ -f "$APORTS/APKBUILD" ]] || { echo "missing $APORTS/APKBUILD" >&2; exit 1; }
[[ -f "$PW/patches/bootstrap.diff" ]] || { echo "missing $PW/patches/bootstrap.diff" >&2; exit 1; }
[[ -f "$OVERLAY" ]] || { echo "missing $OVERLAY" >&2; exit 1; }

# 1. Read aports' pkgver — that's the Mozilla source tarball version we'll use.
#    We use the tarball (not a git clone at PW's SHA) because aports' musl
#    patches are aligned to this tarball; cloning at PW's SHA would mean
#    re-porting aports' patches to a different commit. Cross-check that the
#    Firefox major.minor matches PW's pinned version.
PKGVER=$(awk -F= '$1=="pkgver"{gsub(/"/,"",$2); print $2; exit}' "$APORTS/APKBUILD")
PW_FF_VER=$(cat "$PW/.firefox-version")

# Compare on major.minor only — patch-release drift between aports' tarball and
# PW's pinned source is normal (e.g. aports pins 150.0.2 dot release while PW
# tracks 150.0). FF internal APIs are stable across patch releases on the same
# release branch, so Juggler patches apply cleanly.
majmin() { echo "$1" | awk -F. '{print $1"."$2}'; }
aports_majmin=$(majmin "$PKGVER")
pw_majmin=$(majmin "$PW_FF_VER")

echo "aports firefox pkgver=$PKGVER (majmin=$aports_majmin); PW pins firefox $PW_FF_VER (majmin=$pw_majmin)"

if [[ "$aports_majmin" != "$pw_majmin" ]]; then
  echo "ERROR: aports firefox $PKGVER and PW firefox $PW_FF_VER disagree on major.minor." >&2
  echo "       Reconciliation needed: either bump ALPINE_APORTS_REF, or pin PW_VERSION to a release" >&2
  echo "       whose firefox.browserVersion matches aports' pkgver major.minor." >&2
  exit 2
fi

# 2. Fetch the Mozilla source via git at PW's pinned SHA (NOT the released
#    tarball at aports' pkgver). Reason: Mozilla's release tarball is
#    regenerated for distribution and diverges slightly from the git checkout
#    at the tag — enough that PW's bootstrap.diff fails several hunks in core
#    engine files (nsDocShell.cpp, nsGlobalWindowOuter.cpp, ...). Using PW's
#    exact reference SHA guarantees the bootstrap.diff applies cleanly.
#
#    Aports' musl patches target stable libc-layer files (xpcom/io,
#    config/system-headers.mozbuild, security/sandbox/linux, ...) that don't
#    drift between tarball and git, so they still apply.
PW_SHA=$(awk -F= '$1=="BASE_REVISION"{gsub(/[" ]/,"",$2); print $2; exit}' "$PW/UPSTREAM_CONFIG.sh")
echo "Cloning mozilla-firefox/firefox at $PW_SHA (PW v${PW_VERSION:-?} reference commit)"

mkdir -p "$SRC"
git init -q "$SRC"
git -C "$SRC" remote add origin https://github.com/mozilla-firefox/firefox
# Single-commit fetch — depth=1 + explicit SHA. ~500 MB-ish for Firefox; same
# rough size as the tarball, just delivered over git protocol.
git -C "$SRC" fetch --depth=1 origin "$PW_SHA"
git -C "$SRC" reset --hard FETCH_HEAD --quiet
git -C "$SRC" log -1 --format='%h %s' || true

cd "$SRC"

# 3. Apply aports' musl patches first (libc-layer; ordered as listed in APKBUILD's `source=`).
#    We extract the patch list from APKBUILD by reading lines after `source=` until the closing quote.
#    Skip arch-specific patches we don't need for amd64.
SKIP_REGEX='^(loong|riscv64-|sqlite-ppc|rust1\.90-ppc)'

# Capture to a variable so a failing `patch` inside the loop trips set -e
# (piping awk → while suppresses it because the loop runs in a subshell).
PATCHES=$(awk '
  /^source=/ { in_src = 1; next }
  in_src && /^\s*"/ { in_src = 0; next }
  in_src && /\.patch[[:space:]]*$/ {
    sub(/^\s+/, "", $0); sub(/\s+$/, "", $0); print $0
  }
' "$APORTS/APKBUILD")

for p in $PATCHES; do
  if [[ "$p" =~ $SKIP_REGEX ]]; then
    echo "  skip $p (arch-specific)"
    continue
  fi
  echo "  apply aports/$p"
  patch -p1 -i "$APORTS/$p"
done

# 4. Apply PW's bootstrap.diff on top (engine-layer; should not overlap libc
#    patches). PW ships a monolithic diff covering Linux + macOS + Windows;
#    Mozilla's source drifts slightly between PW's reference SHA and the
#    release tarball, so non-Linux hunks (widget/cocoa, widget/windows) often
#    miss their context. Those files aren't compiled on Linux anyway — strip
#    them with filterdiff so `patch` succeeds cleanly and the failure surface
#    becomes Linux-only.
echo "  filter pw/bootstrap.diff (drop macOS + Windows hunks)"
filterdiff -p1 \
  -x 'widget/cocoa/*' \
  -x 'widget/windows/*' \
  -x 'gfx/thebes/gfxMacFont*' \
  -x 'gfx/thebes/gfxPlatformMac*' \
  -x 'toolkit/xre/MacRunFromDmgUtils*' \
  -x 'toolkit/xre/MacApplicationDelegate*' \
  -x 'toolkit/xre/MacLaunchHelper*' \
  -x 'toolkit/xre/MacAutoreleasePool*' \
  -x '*.mm' \
  "$PW/patches/bootstrap.diff" > /tmp/bootstrap-linux.diff
echo "  apply pw/bootstrap.diff (Linux-only)"
patch -p1 -i /tmp/bootstrap-linux.diff

# 5. Drop Juggler + preferences into Firefox source tree.
#    PW expects juggler/ at the SOURCE ROOT (not toolkit/components/) — their
#    bootstrap.diff patches the top-level moz.build to reference juggler/moz.build.
mkdir -p juggler
cp -a "$PW/juggler/." juggler/

# Preferences: PW lays them under browser/app/profile/firefox.js by appending,
# but the modern convention is to ship them as a separate prefs file Firefox
# loads at runtime. PW's `preferences/` tree contains the canonical layout.
# Copy in-tree where bootstrap.diff expects them.
[[ -d "$PW/preferences" ]] && cp -a "$PW/preferences/." browser/app/profile/

# 6. aports' prepare() extras — things their build() function does on top of
#    patches. We mirror them here:
#    - stab.h: needed by toolkit/crashreporter/google-breakpad on musl
#    - mozilla-api-key: built from mozilla-location.keys (aports' source list).
#      Referenced by aports' mozconfig: --with-mozilla-api-keyfile=...
#    - vendor checksum clearing for rust crates aports' patches modify (cargo
#      refuses to build with modified crates unless their cargo-checksum.json
#      is cleared)
[[ -f "$APORTS/stab.h" ]] && cp "$APORTS/stab.h" toolkit/crashreporter/google-breakpad/src/
[[ -f "$APORTS/mozilla-location.keys" ]] && base64 -d "$APORTS/mozilla-location.keys" > "$SRC/mozilla-api-key"
for crate in audio_thread_priority libc cc; do
  cksum="third_party/rust/$crate/.cargo-checksum.json"
  [[ -f "$cksum" ]] && sed -i 's/\("files":{\)[^}]*/\1/' "$cksum"
done

# 7. Compose mozconfig: aports' + our overlay.
cat "$APORTS/mozconfig" "$OVERLAY" > .mozconfig

# 7. Run aports' configure/build env (mimics APKBUILD `build()`).
export MOZ_BUILD_DATE="$(date '+%Y%m%d%H%M%S')"
export SHELL=/bin/sh
export BUILD_OFFICIAL=1
export MOZILLA_OFFICIAL=1
export USE_SHORT_LIBNAME=1
export MACH_BUILD_PYTHON_NATIVE_PACKAGE_SOURCE=system
export MOZ_NOSPAM=1
export MOZBUILD_STATE_PATH="$SRC/.mozbuild"
export CBUILD="$(cc -dumpmachine)"
export CHOST="$CBUILD"
export CTARGET="$CHOST"
export builddir="$SRC"
ulimit -n 4096 || true

# aports' build() function exports several env vars that the mozconfig +
# rust.configure read directly. We can't just `unset` and let mach autodetect
# because aports' fix-rust-target.patch makes rustc_target a hard require on
# $RUST_TARGET. Mirror the relevant exports here.
export RUST_TARGET="$CTARGET"
export MOZ_APP_REMOTINGNAME=firefox
# Let firefox's own cargo settings drive these — aports unsets them too.
unset CARGO_PROFILE_RELEASE_OPT_LEVEL
unset CARGO_PROFILE_RELEASE_LTO

# aports' mozconfig has `ac_add_options --enable-optimize="$CFLAGS"`. Its
# build() function exports a tuned CFLAGS, but we don't run that function, so
# we set a plain default here. Mozilla rejects an empty --enable-optimize=.
# We're not shipping a hardened distro package — -O2 is fine.
: "${CFLAGS:=-O2 -pipe}"
: "${CXXFLAGS:=$CFLAGS}"
# rpath so the built firefox finds its libs at /usr/lib/firefox (matches the
# install layout the producer image consumer expects).
: "${LDFLAGS:=-Wl,-rpath,/usr/lib/firefox}"
export CFLAGS CXXFLAGS LDFLAGS

# sccache: persisted via the Dockerfile cache mount at /root/.cache/sccache.
# mozconfig.overlay enables `--with-ccache=sccache`, which makes mach wrap CC
# and rustc with sccache. We start the daemon explicitly (idempotent) and cap
# the cache size to avoid filling the GHA cache quota.
export SCCACHE_DIR=/root/.cache/sccache
export SCCACHE_CACHE_SIZE=8G
mkdir -p "$SCCACHE_DIR"
sccache --start-server 2>/dev/null || true
sccache --show-stats || true

# clang/lld version aports pins (must match `clang${ver}` package we installed).
# Read from APKBUILD's `_llvmver` line.
LLVMVER=$(awk -F= '$1=="_llvmver"{gsub(/[^0-9]/,"",$2); print $2; exit}' "$APORTS/APKBUILD")
export CC="clang-${LLVMVER}"
export CXX="clang++-${LLVMVER}"

# `envsubst` substitutes $CBUILD/$CHOST/$builddir inside aports' mozconfig.
envsubst < .mozconfig > .mozconfig.expanded && mv .mozconfig.expanded .mozconfig

# 8. Build. `./mach build` produces obj/dist/firefox/ (unpacked tree) AND
# obj/dist/firefox-*.tar.xz (the same thing tarballed) — we use the unpacked
# tree directly, so no `./mach package` step needed (it would re-run packaging
# and lazy-create a Python "common" virtualenv that's unreliable on Alpine).
#
# We don't `set -e` against ./mach build because mach has a post-build hook
# that re-invokes itself (looks like a configure refresh) and frequently exits
# non-zero on Alpine even though the build succeeded — the "we don't ship a
# distro package" tradeoff. We verify success by checking the artifact instead.
echo "===== START ./mach build ====="
mach_rc=0
./mach build || mach_rc=$?
echo "===== END ./mach build (rc=$mach_rc) ====="

# `./mach build` populates obj/dist/bin/ but NOT obj/dist/firefox/ — the
# unpacked dist tree consumers expect is produced by the package step. Mach's
# package subcommand creates a Python "common" venv that's unreliable on
# Alpine, so we let it fail and fall back to extracting the .tar.xz it
# produces in passing.
echo "===== START ./mach build package ====="
pkg_rc=0
./mach build package || pkg_rc=$?
echo "===== END ./mach build package (rc=$pkg_rc) ====="

# 9. Locate the dist. Try unpacked dir first, then extract from tarball.
set +e
DIST=
for candidate in obj/dist/firefox obj-*/dist/firefox; do
  [ -d "$candidate" ] && DIST="$candidate" && break
done

if [ -z "$DIST" ]; then
  # Tarball fallback. Either obj/dist/firefox-*.tar.xz or obj-*/dist/...
  TARBALL=
  for tb in obj/dist/firefox-*.tar.xz obj-*/dist/firefox-*.tar.xz; do
    [ -f "$tb" ] && TARBALL="$tb" && break
  done
  if [ -n "$TARBALL" ]; then
    echo "===== falling back: extracting $TARBALL ====="
    tar_dir=$(dirname "$TARBALL")
    tar -xf "$TARBALL" -C "$tar_dir"
    [ -d "$tar_dir/firefox" ] && DIST="$tar_dir/firefox"
  fi
fi
set -e

echo "===== DIST resolution: DIST='$DIST' ====="

if [ -z "$DIST" ] || [ ! -x "$DIST/firefox" ]; then
  echo "ERROR: mach build rc=$mach_rc, package rc=$pkg_rc, no firefox binary at '$DIST'" >&2
  echo "obj/ contents:" >&2
  find obj* -maxdepth 3 -type d 2>/dev/null | head -50 >&2 || true
  echo "obj/dist contents:" >&2
  ls -la obj*/dist 2>/dev/null || true
  exit 1
fi
echo "===== Built: $SRC/$DIST (mach rc=$mach_rc, package rc=$pkg_rc; artifact OK) ====="
ls -la "$DIST/" | head -20

# Copy the dist OUT of the cache mount (/work/firefox-src/obj is a buildkit
# cache mount — its contents vanish when the RUN ends, so a subsequent stage
# that COPYs from this image won't see anything there). /work/firefox-dist
# lives in the regular image filesystem and persists to firefox-stage.
echo "===== Staging dist to /work/firefox-dist ====="
mkdir -p /work/firefox-dist
cp -a "$DIST"/. /work/firefox-dist/
echo "Staged: $(du -sh /work/firefox-dist | cut -f1)"
