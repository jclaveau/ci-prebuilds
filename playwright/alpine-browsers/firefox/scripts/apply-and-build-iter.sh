#!/usr/bin/env bash
# Iterative build against the prebuilt-base image.
#
# Assumes /work/firefox-src is already fully patched + built (the prebuilt-base
# image ran apply-and-build.sh once, producing patched source + obj/ tree).
# This script re-applies the diagnostic mutations from clean and runs an
# incremental ./mach build (~5 min vs the ~3h cold compile in apply-and-build.sh).
#
# Usage: apply-and-build-iter.sh
# Reads PW_VERSION from /work/versions.env.
# Writes: /work/firefox-dist/   (the built browser, copied out of obj/dist)

set -euo pipefail

WORK=/work
SRC="$WORK/firefox-src"
APORTS="$WORK/aports"

[[ -d "$SRC" ]] || { echo "missing $SRC (run from prebuilt-base image)" >&2; exit 1; }

# 1. Read PW_VERSION (and the rest of versions.env) into the environment.
set -a && . "$WORK/versions.env" && set +a
echo "===== iter build: PW_VERSION=${PW_VERSION:-?} ====="

# Diagnostic flags — same semantics as apply-and-build.sh. The prebuilt base
# was built with all of these OFF, so on each iteration we re-apply them from
# clean per current flag values.
: "${PW_JUGGLER_ORDER_FIRST:=0}"
: "${PW_JUGGLER_CATEGORY_RENAME:=0}"
: "${PW_JUGGLER_INSTRUMENT:=0}"
: "${PW_JUGGLER_SERVICE_BOOTSTRAP:=0}"
truthy() { case "${1,,}" in 1|true|yes|on) echo 1 ;; *) echo 0 ;; esac; }
PW_JUGGLER_ORDER_FIRST=$(truthy "$PW_JUGGLER_ORDER_FIRST")
PW_JUGGLER_CATEGORY_RENAME=$(truthy "$PW_JUGGLER_CATEGORY_RENAME")
PW_JUGGLER_INSTRUMENT=$(truthy "$PW_JUGGLER_INSTRUMENT")
PW_JUGGLER_SERVICE_BOOTSTRAP=$(truthy "$PW_JUGGLER_SERVICE_BOOTSTRAP")
echo "Flags: PW_JUGGLER_ORDER_FIRST=$PW_JUGGLER_ORDER_FIRST PW_JUGGLER_CATEGORY_RENAME=$PW_JUGGLER_CATEGORY_RENAME PW_JUGGLER_INSTRUMENT=$PW_JUGGLER_INSTRUMENT PW_JUGGLER_SERVICE_BOOTSTRAP=$PW_JUGGLER_SERVICE_BOOTSTRAP"

cd "$SRC"

# 2. Re-apply diagnostic mutations. Each block is idempotent so re-running on
#    a partially-mutated tree is safe (and a no-op when the flag is 0).
echo "===== Re-applying diagnostic mutations ====="

if [[ "$PW_JUGGLER_ORDER_FIRST" == "1" ]]; then
  # Idempotent: detect if /juggler already appears before /remote in the
  # ENABLE_WEBDRIVER block; skip in that case.
  already_first=$(awk '
    /if CONFIG\["ENABLE_WEBDRIVER"\]:/ { in_wd=1; next }
    in_wd && /"\/juggler"/ && !seen_remote { print "yes"; exit }
    in_wd && /"\/remote"/ { seen_remote=1 }
    /^]/ && in_wd { in_wd=0 }
  ' toolkit/toolkit.mozbuild)
  if [[ "$already_first" == "yes" ]]; then
    echo "  PW_JUGGLER_ORDER_FIRST: already reordered — skip"
  else
    echo "  PW_JUGGLER_ORDER_FIRST: moving /juggler before /remote in toolkit/toolkit.mozbuild"
    awk '
      /if CONFIG\["ENABLE_WEBDRIVER"\]:/ { in_webdriver=1 }
      in_webdriver && /"\/juggler"/ { seen_juggler=1; next }
      in_webdriver && /"\/remote"/ && !emitted && !seen_juggler { print "        \"/juggler\","; emitted=1 }
      /^]/ && in_webdriver { in_webdriver=0 }
      { print }
    ' toolkit/toolkit.mozbuild > toolkit/toolkit.mozbuild.new
    mv toolkit/toolkit.mozbuild.new toolkit/toolkit.mozbuild
  fi
fi

if [[ "$PW_JUGGLER_CATEGORY_RENAME" == "1" ]]; then
  # `sed` is idempotent here: replacing m-remote → m-juggler is a no-op once
  # m-remote is gone.
  echo "  PW_JUGGLER_CATEGORY_RENAME: renaming m-remote → m-juggler in juggler/components/components.conf"
  sed -i 's/"command-line-handler": "m-remote"/"command-line-handler": "m-juggler"/' juggler/components/components.conf
fi

if [[ "$PW_JUGGLER_SERVICE_BOOTSTRAP" == "1" ]]; then
  # PW's components.conf declares `"profile-after-change": "Juggler"` — a bare
  # observer name, NOT a contract_id, so the static_components iterator never
  # auto-instantiates JugglerFactory at profile-after-change. As a result
  # JugglerFactory only loads if Mozilla's RemoteAgent activates first (they
  # collide on `command-line-handler:m-remote`; Mozilla shadows PW's entry
  # silently). Rewriting the value to `service,@mozilla.org/remote/juggler;1`
  # forces eager instantiation at profile-after-change, independent of Mozilla.
  if grep -q '"profile-after-change": "service,@mozilla.org/remote/juggler;1"' juggler/components/components.conf 2>/dev/null; then
    echo "  PW_JUGGLER_SERVICE_BOOTSTRAP: service bootstrap already in place — skip"
  else
    echo "  PW_JUGGLER_SERVICE_BOOTSTRAP: rewriting profile-after-change → service,@mozilla.org/remote/juggler;1"
    sed -i 's|"profile-after-change": "Juggler"|"profile-after-change": "service,@mozilla.org/remote/juggler;1"|' juggler/components/components.conf
  fi
fi

if [[ "$PW_JUGGLER_INSTRUMENT" == "1" ]]; then
  if grep -q '\[juggler-trace\]' juggler/components/Juggler.js 2>/dev/null; then
    echo "  PW_JUGGLER_INSTRUMENT: traces already present — skip"
  else
    echo "  PW_JUGGLER_INSTRUMENT: injecting dump() traces into juggler/components/Juggler.js"
    python3 - <<'PYEOF'
import re, pathlib
p = pathlib.Path('juggler/components/Juggler.js')
src = p.read_text()
src = re.sub(
    r"(Services\.scriptloader\.loadSubScript\([^)]+\);)",
    r"dump('[juggler-trace] before SimpleChannel loadSubScript\\n');\n\1\ndump('[juggler-trace] after SimpleChannel loadSubScript\\n');",
    src, count=1)
def annotate(m):
    full = m.group(0)
    uri = m.group(1)
    tail = uri.rsplit('/', 1)[-1].rsplit("'", 1)[0]
    return (f"dump('[juggler-trace] before import {tail}\\n');\n{full}\n"
            f"dump('[juggler-trace] after  import {tail}\\n');")
src = re.sub(
    r"const\s*\{[^}]+\}\s*=\s*ChromeUtils\.importESModule\(([^)]+)\);",
    annotate, src)
src = src.replace(
    "export class Juggler {",
    "dump('[juggler-trace] before class Juggler decl\\n');\nexport class Juggler {")
src = src.replace(
    "export var JugglerFactory",
    "dump('[juggler-trace] before JugglerFactory declaration\\n');\nexport var JugglerFactory")
p.write_text(src)
print(f"  injected {src.count('[juggler-trace]')} trace points into Juggler.js")
PYEOF
  fi
fi

# 3. Re-export the build env. The prebuilt base set these in its RUN scope,
#    but env doesn't persist across image layers — we re-establish them here.
echo "===== Re-exporting build env ====="

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

export RUST_TARGET="$CTARGET"
export MOZ_APP_REMOTINGNAME=firefox
unset CARGO_PROFILE_RELEASE_OPT_LEVEL
unset CARGO_PROFILE_RELEASE_LTO

: "${CFLAGS:=-O2 -pipe}"
: "${CXXFLAGS:=$CFLAGS}"
: "${LDFLAGS:=-Wl,-rpath,/usr/lib/firefox}"
export CFLAGS CXXFLAGS LDFLAGS

export SCCACHE_DIR=/root/.cache/sccache
export SCCACHE_CACHE_SIZE=8G
mkdir -p "$SCCACHE_DIR"
sccache --start-server 2>/dev/null || true
sccache --show-stats || true

LLVMVER=$(awk -F= '$1=="_llvmver"{gsub(/[^0-9]/,"",$2); print $2; exit}' "$APORTS/APKBUILD")
export CC="clang-${LLVMVER}"
export CXX="clang++-${LLVMVER}"

# 4. Incremental build. Should be fast — obj/ is populated from the prebuilt
#    base, so only the files touched by the diagnostic mutations recompile.
echo "===== START ./mach build (incremental) ====="
mach_rc=0
./mach build || mach_rc=$?
echo "===== END ./mach build (rc=$mach_rc) ====="

echo "===== START ./mach build package ====="
pkg_rc=0
./mach build package || pkg_rc=$?
echo "===== END ./mach build package (rc=$pkg_rc) ====="

# 5. Locate the dist (same fallback chain as apply-and-build.sh).
set +e
DIST=
for candidate in obj/dist/firefox obj-*/dist/firefox; do
  [ -d "$candidate" ] && DIST="$candidate" && break
done

if [ -z "$DIST" ]; then
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

# 6. Stage the dist to /work/firefox-dist (regular image fs, survives the RUN).
echo "===== Staging dist to /work/firefox-dist ====="
rm -rf /work/firefox-dist
mkdir -p /work/firefox-dist
cp -a "$DIST"/. /work/firefox-dist/
echo "Staged: $(du -sh /work/firefox-dist | cut -f1)"
