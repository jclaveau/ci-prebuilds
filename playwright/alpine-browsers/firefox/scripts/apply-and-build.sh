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

# Diagnostic flags (default off; flipped by the debug workflows):
#   PW_SKIP_APORTS=1        — don't apply Alpine patches; use Mozilla-default
#                             mach environment. Used by the glibc-debug workflow
#                             to isolate PW patches from musl-specific changes.
#   PW_JUGGLER_ORDER_FIRST=1 — after applying patches, move "/juggler" to BEFORE
#                             "/remote" in toolkit/toolkit.mozbuild's DIRS list.
#                             Tests the hypothesis that Mozilla's RemoteAgent
#                             wins the m-remote category collision by ordering.
#   PW_JUGGLER_CATEGORY_RENAME=1 — rename "m-remote" → "m-juggler" in
#                             juggler/components/components.conf. Tests the
#                             same hypothesis from the opposite direction.
#   PW_ENABLE_TESTS=1       — append `ac_add_options --enable-tests` to
#                             mozconfig so xpcshell/gtest/mochitest harness is
#                             included. Used by the validation workflow.
#   PW_JUGGLER_INSTRUMENT=1 — inject `dump()` traces into Juggler.js after each
#                             ESM import + at the factory entry. Helps pinpoint
#                             which step hangs when -juggler-pipe doesn't
#                             reach "Juggler listening to the pipe".
#   PW_MAX_LOGGING=1        — set MOZ_LOG_FILE + MOZ_LOG=all:5 during the smoke
#                             stage to capture component-load behavior.
: "${PW_SKIP_APORTS:=0}"
: "${PW_JUGGLER_ORDER_FIRST:=0}"
: "${PW_JUGGLER_CATEGORY_RENAME:=0}"
: "${PW_ENABLE_TESTS:=0}"
: "${PW_JUGGLER_INSTRUMENT:=0}"
: "${PW_MAX_LOGGING:=0}"
# Normalize truthy values ("true"/"yes"/"1") → "1"; everything else → "0".
truthy() { case "${1,,}" in 1|true|yes|on) echo 1 ;; *) echo 0 ;; esac; }
PW_SKIP_APORTS=$(truthy "$PW_SKIP_APORTS")
PW_JUGGLER_ORDER_FIRST=$(truthy "$PW_JUGGLER_ORDER_FIRST")
PW_JUGGLER_CATEGORY_RENAME=$(truthy "$PW_JUGGLER_CATEGORY_RENAME")
PW_ENABLE_TESTS=$(truthy "$PW_ENABLE_TESTS")
PW_JUGGLER_INSTRUMENT=$(truthy "$PW_JUGGLER_INSTRUMENT")
PW_MAX_LOGGING=$(truthy "$PW_MAX_LOGGING")
echo "Flags: PW_SKIP_APORTS=$PW_SKIP_APORTS PW_JUGGLER_ORDER_FIRST=$PW_JUGGLER_ORDER_FIRST PW_JUGGLER_CATEGORY_RENAME=$PW_JUGGLER_CATEGORY_RENAME PW_ENABLE_TESTS=$PW_ENABLE_TESTS"

[[ -f "$PW/patches/bootstrap.diff" ]] || { echo "missing $PW/patches/bootstrap.diff" >&2; exit 1; }
[[ -f "$OVERLAY" ]] || { echo "missing $OVERLAY" >&2; exit 1; }
if [[ "$PW_SKIP_APORTS" != "1" ]]; then
  [[ -f "$APORTS/APKBUILD" ]] || { echo "missing $APORTS/APKBUILD (or set PW_SKIP_APORTS=1)" >&2; exit 1; }
fi

# 1. Read aports' pkgver — that's the Mozilla source tarball version we'll use.
#    We use the tarball (not a git clone at PW's SHA) because aports' musl
#    patches are aligned to this tarball; cloning at PW's SHA would mean
#    re-porting aports' patches to a different commit. Cross-check that the
#    Firefox major.minor matches PW's pinned version.
PW_FF_VER=$(cat "$PW/.firefox-version")
if [[ "$PW_SKIP_APORTS" == "1" ]]; then
  echo "PW_SKIP_APORTS=1 — skipping aports version check; PW pins firefox $PW_FF_VER"
else
  PKGVER=$(awk -F= '$1=="pkgver"{gsub(/"/,"",$2); print $2; exit}' "$APORTS/APKBUILD")

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
#    Skipped entirely if PW_SKIP_APORTS=1 (used by the glibc-debug workflow).
if [[ "$PW_SKIP_APORTS" == "1" ]]; then
  echo "  skip all aports patches (PW_SKIP_APORTS=1)"
else
  # We extract the patch list from APKBUILD by reading lines after `source=` until the closing quote.
  # Skip arch-specific patches we don't need for amd64.
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
fi

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

# 5a. DIAGNOSTIC: PW_JUGGLER_ORDER_FIRST — move "/juggler" to BEFORE "/remote"
#     in toolkit/toolkit.mozbuild's WebDriver DIRS list. Tests whether Mozilla
#     RemoteAgent winning the m-remote category collision is the reason
#     Juggler's command-line-handler is dormant.
if [[ "$PW_JUGGLER_ORDER_FIRST" == "1" ]]; then
  echo "  DIAGNOSTIC: moving /juggler before /remote in toolkit/toolkit.mozbuild"
  # awk script: when we see the line `"/remote",` inside ENABLE_WEBDRIVER DIRS,
  # emit `"/juggler",` first if we haven't already.
  awk '
    /if CONFIG\["ENABLE_WEBDRIVER"\]:/ { in_webdriver=1 }
    in_webdriver && /"\/juggler"/ { seen_juggler=1; next }   # drop existing /juggler line
    in_webdriver && /"\/remote"/ && !emitted && !seen_juggler { print "        \"/juggler\","; emitted=1 }
    /^]/ && in_webdriver { in_webdriver=0 }
    { print }
  ' toolkit/toolkit.mozbuild > toolkit/toolkit.mozbuild.new
  mv toolkit/toolkit.mozbuild.new toolkit/toolkit.mozbuild
  echo "  (after) WebDriver DIRS:"
  awk '/if CONFIG\["ENABLE_WEBDRIVER"\]:/,/^]/' toolkit/toolkit.mozbuild | head -15
fi

# 5b. DIAGNOSTIC: PW_JUGGLER_CATEGORY_RENAME — rename "m-remote" → "m-juggler"
#     in juggler/components/components.conf. Avoids the collision with
#     Mozilla's RemoteAgent (also "m-remote") so the JS Juggler factory
#     registers under a distinct entry name.
if [[ "$PW_JUGGLER_CATEGORY_RENAME" == "1" ]]; then
  echo "  DIAGNOSTIC: renaming m-remote → m-juggler in juggler/components/components.conf"
  sed -i 's/"command-line-handler": "m-remote"/"command-line-handler": "m-juggler"/' juggler/components/components.conf
fi

# 5c. DIAGNOSTIC: PW_JUGGLER_INSTRUMENT — inject `dump()` traces into
#     Juggler.js after each ESM import + at factory/handler entry points. If
#     Juggler init silently hangs on musl, the last printed trace point tells
#     us which import or initialization step is the culprit.
#     `dump()` is a Firefox global that writes directly to stderr,
#     bypassing console + log filtering. Always visible in the smoke output.
if [[ "$PW_JUGGLER_INSTRUMENT" == "1" ]]; then
  echo "  DIAGNOSTIC: instrumenting juggler/components/Juggler.js with dump() traces"
  python3 - <<'PYEOF'
import re, pathlib
p = pathlib.Path('juggler/components/Juggler.js')
src = p.read_text()
# Insert a dump() after each top-level statement we want to trace.
# Match: `Services.scriptloader.loadSubScript('...');`
src = re.sub(
    r"(Services\.scriptloader\.loadSubScript\([^)]+\);)",
    r"dump('[juggler-trace] before SimpleChannel loadSubScript\\n');\n\1\ndump('[juggler-trace] after SimpleChannel loadSubScript\\n');",
    src, count=1)
# Match each importESModule line and annotate before/after with the URI tail.
def annotate(m):
    full = m.group(0)
    uri = m.group(1)
    tail = uri.rsplit('/', 1)[-1].rsplit("'", 1)[0]
    return (f"dump('[juggler-trace] before import {tail}\\n');\n{full}\n"
            f"dump('[juggler-trace] after  import {tail}\\n');")
src = re.sub(
    r"const\s*\{[^}]+\}\s*=\s*ChromeUtils\.importESModule\(([^)]+)\);",
    annotate, src)
# Mark factory instantiation.
src = src.replace(
    "export class Juggler {",
    "dump('[juggler-trace] before class Juggler decl\\n');\nexport class Juggler {")
# Mark the JugglerFactory function (the XPCOM factory entry point).
src = src.replace(
    "export var JugglerFactory",
    "dump('[juggler-trace] before JugglerFactory declaration\\n');\nexport var JugglerFactory")
p.write_text(src)
print(f"  injected {src.count('[juggler-trace]')} trace points into Juggler.js")
PYEOF
fi

# 6. aports' prepare() extras — things their build() function does on top of
#    patches. Skipped under PW_SKIP_APORTS.
if [[ "$PW_SKIP_APORTS" != "1" ]]; then
  # stab.h: needed by toolkit/crashreporter/google-breakpad on musl
  [[ -f "$APORTS/stab.h" ]] && cp "$APORTS/stab.h" toolkit/crashreporter/google-breakpad/src/
  # mozilla-api-key: built from mozilla-location.keys (aports' source list).
  # Referenced by aports' mozconfig: --with-mozilla-api-keyfile=...
  [[ -f "$APORTS/mozilla-location.keys" ]] && base64 -d "$APORTS/mozilla-location.keys" > "$SRC/mozilla-api-key"
  # vendor checksum clearing for rust crates aports' patches modify (cargo
  # refuses to build with modified crates unless their cargo-checksum.json
  # is cleared)
  for crate in audio_thread_priority libc cc; do
    cksum="third_party/rust/$crate/.cargo-checksum.json"
    [[ -f "$cksum" ]] && sed -i 's/\("files":{\)[^}]*/\1/' "$cksum"
  done
fi

# 7. Compose mozconfig: aports' + our overlay (or minimal default if skipping aports).
if [[ "$PW_SKIP_APORTS" == "1" ]]; then
  # Minimal Mozilla-default mozconfig — no system libs, all bundled. We're
  # diagnosing PW patch behavior, not shipping a tuned distro package.
  #
  # --disable-lto + RUSTFLAGS below: the default Firefox release config builds
  # the gkrust crate with `-Clto -C debuginfo=2`, which OOM-kills rustc on
  # GHA's `ubuntu-latest` (~7 GB usable RAM) during the LTO link phase. We
  # don't ship this binary, so we trade some optimization headroom for a
  # build that actually completes. Aports' build doesn't hit this because it
  # runs on Alpine builders with more memory budget AND its mozconfig already
  # tunes LTO down.
  cat > .mozconfig <<'EOF'
ac_add_options --disable-bootstrap
ac_add_options --disable-crashreporter
ac_add_options --disable-debug
ac_add_options --disable-updater
ac_add_options --enable-application=browser
ac_add_options --enable-release
ac_add_options --enable-optimize="-O2 -pipe"
ac_add_options --enable-linker=lld
ac_add_options --with-libclang-path=/usr/lib/llvm-19/lib
ac_add_options --without-wasm-sandboxed-libraries
ac_add_options --disable-lto
mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/obj
EOF
  cat "$OVERLAY" >> .mozconfig
else
  cat "$APORTS/mozconfig" "$OVERLAY" > .mozconfig
fi

# 7a. DIAGNOSTIC: PW_ENABLE_TESTS — include xpcshell + gtest + mochitest
#     harness so the validation workflow can run Mozilla's own self-tests.
if [[ "$PW_ENABLE_TESTS" == "1" ]]; then
  echo "  DIAGNOSTIC: enabling --enable-tests in mozconfig"
  # Strip aports' --disable-tests first (last setting wins, but be explicit)
  sed -i '/^ac_add_options --disable-tests/d' .mozconfig
  echo 'ac_add_options --enable-tests' >> .mozconfig
fi

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

# Under PW_SKIP_APORTS=1 (glibc-debug workflow), forcibly disable Rust LTO and
# strip debuginfo. Two-thirds of GHA hosted runners can't fit the `gkrust` LTO
# link step in memory (rustc gets OOM-killed with exit 254). The mozconfig's
# `--disable-lto` covers C/C++ LTO but Firefox's Rust crates pick LTO up from
# CARGO_PROFILE_RELEASE_LTO / RUSTFLAGS. Setting RUSTFLAGS here bypasses both
# the cargo profile and any inherited toolchain default. Diagnostic-only path —
# the musl producer build (aports' mozconfig) keeps LTO on for shipping perf.
if [[ "$PW_SKIP_APORTS" == "1" ]]; then
  export CARGO_PROFILE_RELEASE_LTO=false
  export RUSTFLAGS="-Copt-level=2 -Cdebuginfo=0 -Cembed-bitcode=no"
  echo "  PW_SKIP_APORTS=1: forcing RUSTFLAGS='$RUSTFLAGS' to avoid GHA-runner OOM"
fi

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

# clang/lld version: aports pins via `_llvmver`. When skipping aports, fall back
# to whatever `clang` / `clang++` the builder image provides (e.g. clang-19 on
# Ubuntu 24.04).
if [[ "$PW_SKIP_APORTS" == "1" ]]; then
  export CC="${CC:-clang}"
  export CXX="${CXX:-clang++}"
  echo "  CC=$CC CXX=$CXX (PW_SKIP_APORTS=1 defaults)"
else
  LLVMVER=$(awk -F= '$1=="_llvmver"{gsub(/[^0-9]/,"",$2); print $2; exit}' "$APORTS/APKBUILD")
  export CC="clang-${LLVMVER}"
  export CXX="clang++-${LLVMVER}"
fi

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
#
# Under PW_SKIP_APORTS=1 (glibc-debug workflow) we skip packaging entirely:
# Mozilla's package-manifest.in expects bundled NSS but we configure with
# --with-system-nss, so packaging fails with "missing libnss3.so" errors and
# can also OOM on hosted runners during the libxul link/pack. For diagnostic
# use we just need a runnable firefox, which obj/dist/bin/ already provides.
pkg_rc=0
if [[ "$PW_SKIP_APORTS" == "1" ]]; then
  echo "===== SKIP ./mach build package (PW_SKIP_APORTS=1; use obj/dist/bin/ directly) ====="
else
  echo "===== START ./mach build package ====="
  ./mach build package || pkg_rc=$?
  echo "===== END ./mach build package (rc=$pkg_rc) ====="
fi

# 9. Locate the dist. Try the packaged unpacked dir first, then the
# .tar.xz fallback, then obj/dist/bin/ (post-`./mach build`, packaging-free).
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

if [ -z "$DIST" ]; then
  # Packaging-free fallback (PW_SKIP_APORTS=1 path): obj/dist/bin/ has the
  # built firefox binary + libxul.so + chrome/ + omni.ja + everything else
  # needed at runtime. It's the same content the packaged dist contains —
  # just without the post-process layout.
  for candidate in obj/dist/bin obj-*/dist/bin; do
    if [ -d "$candidate" ] && [ -x "$candidate/firefox" ]; then
      DIST="$candidate"
      break
    fi
  done
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
# `| head -20` would trigger SIGPIPE under `set -o pipefail` (ls writes ~100s
# of lines, head closes stdin at 20, ls exits 141, pipefail propagates). Use
# `|| true` so the diagnostic dump can't kill a build that already succeeded.
ls -la "$DIST/" | head -20 || true

# Copy the dist OUT of the cache mount (/work/firefox-src/obj is a buildkit
# cache mount — its contents vanish when the RUN ends, so a subsequent stage
# that COPYs from this image won't see anything there). /work/firefox-dist
# lives in the regular image filesystem and persists to firefox-stage.
#
# Mozilla's obj/dist/bin/ is a tree of SYMLINKS pointing back into obj/...
# (and obj/dist/bin/test-stage/, etc.). cp -a copies the symlinks themselves,
# which all become dangling once the cache mount unmounts. Use cp -aL to
# dereference — symlinks become real files, and the staged tree survives.
echo "===== Staging dist to /work/firefox-dist ====="
mkdir -p /work/firefox-dist
cp -aL "$DIST"/. /work/firefox-dist/ 2>/dev/null || cp -a "$DIST"/. /work/firefox-dist/
echo "Staged: $(du -sh /work/firefox-dist | cut -f1)"

# Bundle transitive .so deps via ldd-walk + RPATH=$ORIGIN. Aports' Firefox
# LDFLAGS hardcodes RUNPATH=/usr/lib/firefox; the artifact ships at any path
# the consumer chooses (/ms-playwright/firefox-{rev}/firefox in PW SDK
# auto-discovery), so the loader can't find peer/system libs. Mirror the
# chromium-headless-shell treatment: bundle system .so deps into the dist
# tree and patchelf RPATH=$ORIGIN on every binary + .so. Result: a fully
# self-contained artifact that works on any musl base regardless of ICU/
# NSPR/NSS/libstdc++ version drift.
echo "===== Bundling .so deps + patchelf RPATH=\$ORIGIN ====="
DST=/work/firefox-dist
FF_BINS="$DST/firefox $DST/firefox-bin $DST/glxtest $DST/vaapitest $DST/pingsender"

# Universal-runtime libs that MUST resolve from the consumer's base, not the
# bundle. The binary's ELF interpreter is hardcoded to the system loader
# (/lib/ld-musl-x86_64.so.1) — patchelf --set-interpreter can't be relative —
# so the loader+libc ABI is fixed by the consumer's musl version. If we bundle
# our build-time copies, peer .so files resolve them via RPATH=$ORIGIN and end
# up calling a different libc than the loader, which corrupts dynamic linker
# state and segfaults at XPCOM init when the consumer base's musl version
# diverges from the builder's (e.g. consumer alpine 3.21 musl 1.2.5-r11 vs
# builder alpine:edge musl 1.2.6-r0). Skip and let the system loader pick up
# the consumer's matching copies via default search paths.
# - ld-musl-x86_64.so.1: musl loader/libc. Same file as libc.musl-x86_64.so.1.
# - libgcc_s.so.1, libstdc++.so.6: GCC runtime/C++ stdlib. Tracks the system
#   toolchain; bundling a foreign-version copy breaks libc-coupled symbols
#   (__cxa_thread_atexit_impl etc).
EXCLUDE_LIBS="ld-musl-x86_64.so.1 libc.musl-x86_64.so.1 libgcc_s.so.1 libstdc++.so.6"

# Walk ldd on a target, copy system .so deps into $DST (top level only —
# nested gmp-clearkey/ etc. dlopen explicitly and inherit firefox's RPATH).
ldd_walk() {
  local target="$1"
  [ -e "$target" ] || return 0
  for so in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/' || true); do
    base=$(basename "$so")
    case " $EXCLUDE_LIBS " in *" $base "*) continue ;; esac
    [ -f "$so" ] && [ ! -f "$DST/$base" ] && cp -aL "$so" "$DST"/ || true
  done
}

# Pass 1: walk binaries + already-bundled .so files.
for t in $FF_BINS; do ldd_walk "$t"; done
for so in "$DST"/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done
# Pass 2: deps-of-deps for second-order resolution (libicui18n -> libicuuc, etc.)
for so in "$DST"/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done
# Pass 3: rare third-order (libstdc++ -> libgcc_s, etc.)
for so in "$DST"/*.so*; do [ -L "$so" ] || ldd_walk "$so"; done

# Patchelf RPATH=$ORIGIN on every binary + top-level .so. The loader uses
# RPATH of the LOADING module, so libxul.so needs $ORIGIN to find peer libs
# in the same dir.
for t in $FF_BINS; do
  [ -f "$t" ] && patchelf --set-rpath '$ORIGIN' "$t" 2>/dev/null || true
done
for so in "$DST"/*.so*; do
  [ -L "$so" ] && continue
  patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
done

# Sanity check: no "not found" in libxul ldd. Fail loud at producer time,
# not silently at consumer runtime. (firefox-bin is small; libxul.so is the
# fat one and most likely to surface missing deps.)
missing=$(ldd "$DST/libxul.so" 2>/dev/null | grep 'not found' || true)
if [ -n "$missing" ]; then
  echo "ERROR: libxul.so still has unresolved deps after bundle:" >&2
  echo "$missing" >&2
  echo "---firefox binary ldd:" >&2
  ldd "$DST/firefox" 2>&1 | head -30 >&2
  exit 1
fi
echo "===== Self-contained artifact: $(du -sh "$DST" | cut -f1) ====="
