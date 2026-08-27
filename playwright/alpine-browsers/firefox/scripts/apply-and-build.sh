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

# Used by the aports check below AND by the post-checkout source check, which runs
# even when PW_SKIP_APORTS=1 — so it cannot live inside that branch.
majmin() { echo "$1" | awk -F. '{print $1"."$2}'; }

if [[ "$PW_SKIP_APORTS" == "1" ]]; then
  echo "PW_SKIP_APORTS=1 — skipping aports version check; PW pins firefox $PW_FF_VER"
else
  PKGVER=$(awk -F= '$1=="pkgver"{gsub(/"/,"",$2); print $2; exit}' "$APORTS/APKBUILD")

  # Compare on major.minor only — patch-release drift between aports' tarball and
  # PW's pinned source is normal (e.g. aports pins 150.0.2 dot release while PW
  # tracks 150.0). FF internal APIs are stable across patch releases on the same
  # release branch, so Juggler patches apply cleanly.
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

# The CHECKOUT decides what we ship — not either version pin — and Playwright's own
# release tag can disagree with itself. At v1.60.0, browsers.json says firefox
# 150.0.2 while browser_patches' BASE_REVISION is 4eb5a4f7, whose version.txt reads
# 147.0.1. The aports check above compares two pins that both said 150.0.2, passed,
# and the build then spent 3h10m producing a 147.0.1 binary that got published as
# ff-150.0.2. Nothing compared the source tree to anything until a perf probe read
# browser.version() weeks later.
#
# major.minor, like the aports check: patch drift between a release-branch tip and
# the published build is normal, a major.minor gap means the wrong source tree.
SRC_VERSION_FILE="$SRC/browser/config/version.txt"
[[ -f "$SRC_VERSION_FILE" ]] || { echo "ERROR: no $SRC_VERSION_FILE in the checkout" >&2; exit 2; }
SRC_FF_VER=$(tr -d '[:space:]' < "$SRC_VERSION_FILE")
echo "cloned source is firefox $SRC_FF_VER; PW v${PW_VERSION:-?} publishes $PW_FF_VER"

if [[ "$(majmin "$SRC_FF_VER")" != "$(majmin "$PW_FF_VER")" ]]; then
  echo "ERROR: the source at $PW_SHA is firefox $SRC_FF_VER, but PW publishes $PW_FF_VER." >&2
  echo "       PW's browsers.json and its browser_patches/firefox/UPSTREAM_CONFIG.sh" >&2
  echo "       disagree at this tag. Building would ship a $SRC_FF_VER binary under a" >&2
  echo "       $PW_FF_VER tag. Reconcile by pinning BASE_REVISION to a commit whose" >&2
  echo "       browser/config/version.txt matches, or by tagging the artifact for the" >&2
  echo "       version actually built." >&2
  exit 2
fi

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

# FIX (2026-07-20): PW v1.60.0's juggler omits `location` on Page.uncaughtError,
# but the v1.60.0 CLIENT (browserContextDispatcher.ts) reads
# `pageError.location.url` UNCONDITIONALLY → "Cannot read properties of undefined
# (reading 'url')" crashes the test worker on EVERY page-level uncaught error
# (pageerror / weberror / worker error / CSP-blocked eval), cascading via
# "Test ended". This is a version-skew inside the pinned tag (upstream `main`
# added the location plumbing), NOT a musl divergence. Port main's location field
# through the two emit paths + the protocol type. Assertive replacements so a
# future juggler reformat fails the build loudly instead of re-shipping the crash.
echo "  FIX: thread location through Page.uncaughtError (ports microsoft/playwright main)"
python3 - <<'PYEOF'
import pathlib
import sys

def patch(path, pairs):
    p = pathlib.Path(path); s = p.read_text()
    for old, new in pairs:
        assert old in s, f"anchor not found in {path}:\n{old!r}"
        s = s.replace(old, new, 1)
    p.write_text(s)

# Upstream landed this plumbing between 1.60 and 1.62: v1.62.0's Runtime.js builds
# `errorLocation` itself, so the anchors below no longer match and the port is
# redundant. Detect the fix rather than the version — the patch has to keep
# applying to older pins and no-op on newer ones. If NEITHER the fix nor the
# anchor is present the asserts below still fail loudly, which is the property
# this block was written for.
if 'const errorLocation = {' in pathlib.Path('juggler/content/Runtime.js').read_text():
    print("  SKIP: juggler already threads location upstream — nothing to port")
    sys.exit(0)

patch('juggler/content/Runtime.js', [
  ("        const errorWindow = Services.wm.getOuterWindowWithId(message.outerWindowID);\n"
   "        if (message.category === 'Web Worker' && message.logLevel === Ci.nsIConsoleMessage.error) {\n"
   "          emitEvent(this.events.onErrorFromWorker, errorWindow, message.message, '' + message.stack);",
   "        const errorWindow = Services.wm.getOuterWindowWithId(message.outerWindowID);\n"
   "        const errorLocation = {\n"
   "          lineNumber: message.lineNumber - 1,\n"
   "          columnNumber: message.columnNumber - 1,\n"
   "          url: message.sourceName,\n"
   "        };\n"
   "        if (message.category === 'Web Worker' && message.logLevel === Ci.nsIConsoleMessage.error) {\n"
   "          emitEvent(this.events.onErrorFromWorker, errorWindow, message.message, '' + message.stack, errorLocation);"),
  ("          emitEvent(this.events.onRuntimeError, {\n"
   "            executionContext,\n"
   "            message: message.errorMessage,\n"
   "            stack: message.stack ? message.stack.toString() : '',\n"
   "          });",
   "          emitEvent(this.events.onRuntimeError, {\n"
   "            executionContext,\n"
   "            message: message.errorMessage,\n"
   "            stack: message.stack ? message.stack.toString() : '',\n"
   "            location: errorLocation,\n"
   "          });"),
])

patch('juggler/content/PageAgent.js', [
  ("      this._runtime.events.onErrorFromWorker((domWindow, message, stack) => {",
   "      this._runtime.events.onErrorFromWorker((domWindow, message, stack, location) => {"),
  ("        this._browserPage.emit('pageUncaughtError', {\n"
   "          frameId: frame.id(),\n"
   "          message,\n"
   "          stack,\n"
   "        });",
   "        this._browserPage.emit('pageUncaughtError', {\n"
   "          frameId: frame.id(),\n"
   "          message,\n"
   "          stack,\n"
   "          location,\n"
   "        });"),
  ("  _onRuntimeError({ executionContext, message, stack }) {\n"
   "    this._browserPage.emit('pageUncaughtError', {\n"
   "      frameId: executionContext.auxData().frameId,\n"
   "      message: message.toString(),\n"
   "      stack: stack.toString(),\n"
   "    });",
   "  _onRuntimeError({ executionContext, message, stack, location }) {\n"
   "    this._browserPage.emit('pageUncaughtError', {\n"
   "      frameId: executionContext.auxData().frameId,\n"
   "      message: message.toString(),\n"
   "      stack: stack.toString(),\n"
   "      location,\n"
   "    });"),
])

patch('juggler/protocol/Protocol.js', [
  ("    'uncaughtError': {\n"
   "      frameId: t.String,\n"
   "      message: t.String,\n"
   "      stack: t.String,\n"
   "    },",
   "    'uncaughtError': {\n"
   "      frameId: t.String,\n"
   "      message: t.String,\n"
   "      stack: t.String,\n"
   "      location: runtimeTypes.ScriptLocation,\n"
   "    },"),
])
print("  juggler location patch applied (Runtime.js + PageAgent.js + Protocol.js)")
PYEOF

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
  # is cleared). Read the crate list out of APKBUILD's prepare() rather than
  # snapshotting it: aports adds crates as its patches grow (zeitstempel,
  # wgpu-hal and alsa arrived with time64.patch), and a missing one fails the
  # build ~4 min in with "the listed checksum of ... has changed".
  CRATES=$(awk '$1 ~ /^_clear_vendor_checksums$/ { print $2 }' "$APORTS/APKBUILD")
  [[ -n "$CRATES" ]] || { echo "no _clear_vendor_checksums calls found in APKBUILD" >&2; exit 1; }
  echo "  clear vendor checksums: $(echo $CRATES | tr '\n' ' ')"
  for crate in $CRATES; do
    cksum="third_party/rust/$crate/.cargo-checksum.json"
    [[ -f "$cksum" ]] || { echo "  no vendored crate third_party/rust/$crate" >&2; continue; }
    sed -i 's/\("files":{\)[^}]*/\1/' "$cksum"
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

# 7b. Build libpng and zlib from Mozilla's tree instead of Alpine's.
#
# aports asks for the system copies; the PNG our screenshots produce is then
# 40150 B against Playwright's official build's 26801 B for a bitmap proven
# identical — the canvas control's JPEG is byte-for-byte the same on both
# sides, same sha, so only the encoder can differ.
#
# Measured ours-vs-ours on one runner (32640911593, 32641010090): PNG
# screenshots 0.70-0.78x, i.e. ~25% faster, with png_viewport falling
# 25018 -> 12188 B on the real page. The JPEG rows stay at 0.97-1.21x around
# unity across both runs, which is the control: same page, same capture, same
# transport, identical bytes and sha. Every row is flagged n.s. individually
# because the single-row noise floor is ~±20%, but PNG never approached 1.0 in
# four measurements while JPEG never approached 0.75 in six.
#
# BOTH or neither. Removing one alone changes nothing at all — verified by
# DT_NEEDED on all four arms, and both single arms did drop their library.
# With --with-system-png kept, PNG encoding happens inside libpng16.so.16,
# which carries its OWN linkage to system libz, so an in-tree zlib is compiled
# into libxul and never sits on the PNG path. And Mozilla's libpng against
# system zlib is byte-identical to Alpine's. Only with both in-tree does the
# path reach Mozilla's deflate.
#
# Costs +122,670 B of image. --with-system-jpeg deliberately stays: the JPEG
# control already matches the reference byte-for-byte, so it is not part of
# this.
#
# Deleted rather than overridden with --without-system-*: moz.configure
# rejects a --with and a --without of the same option in one mozconfig.
# A no-op here is acceptable rather than fatal: if aports ever stops asking
# for the system copies we are already where we want to be. It is still worth
# saying out loud, because the removal below would then be dead code.
if ! grep -qE -- '^ac_add_options --with-system-(png|zlib)$' .mozconfig; then
  echo "::warning::aports no longer sets --with-system-png/zlib — removal is a no-op"
fi
sed -i \
  -e '/^ac_add_options --with-system-png$/d' \
  -e '/^ac_add_options --with-system-zlib$/d' \
  .mozconfig
# `if`, not `grep && { exit 1; }`: under `set -e` the && form aborts on the
# GOOD path, where grep correctly finds nothing and returns 1.
if grep -qE -- '^ac_add_options --with-system-(png|zlib)$' .mozconfig; then
  echo "ERROR: a --with-system-png/zlib line survived the removal" >&2
  exit 1
fi
echo "  imaging: libpng + zlib built from Mozilla's tree (system copies removed)"

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

# MOZILLA_OFFICIAL=1 makes packaging include source info, and `mach build
# package` then preprocesses obj/source-repo.h for MOZ_SOURCE_URL. We build
# from a release TARBALL, so nothing populates that header and the packager
# dies with "no preprocessor directives found" — 1.5s in, after a ~4h compile.
# aports never hits this because it packages with `./mach install`, which does
# not run make-sourcestamp-file at all.
#
# Set the two variables the header is generated from. They are metadata only:
# they appear in about:buildconfig, and nothing links against them.
export MOZ_SOURCE_REPO="https://hg.mozilla.org/releases/mozilla-release"
# PKGVER is only set on the aports path; PW_SKIP_APORTS builds fall back to
# PW's pinned version so `set -u` cannot abort here.
_src_ver="${PKGVER:-$PW_FF_VER}"
export MOZ_SOURCE_CHANGESET="FIREFOX_${_src_ver//./_}_RELEASE"
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
# the musl producer build gets LTO from mozconfig.overlay, not from aports'
# mozconfig, which has no `lto` line at all.
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

# What did configure ACTUALLY decide about hardening? The perf/firefox-no-hardening
# arm came back with a byte-identical .text, and nothing in the build log can
# separate "the flag changed no codegen" from "the flag never reached the
# compiler" — moz.configure turns hardening ON when the option is absent as well
# as when it is passed, so deleting the line is a silent no-op. autoconf.mk is
# what configure wrote, so it is the only cheap discriminator.
#
# MOZ_OPTIMIZE is the positive control: it must always print. If the whole block
# comes back empty, the grep is broken, not the hardening.
AUTOCONF_MK="$SRC/obj/config/autoconf.mk"
if [[ -r "$AUTOCONF_MK" ]]; then
  echo "===== configure flags (hardening + control) ====="
  grep -E '^(MOZ_HARDENING|MOZ_TRIVIAL_AUTO_VAR_INIT|MOZ_OPTIMIZE|MOZ_LTO|MOZ_PGO)' \
    "$AUTOCONF_MK" | sed 's/^/  /' || echo "  (no match — grep is broken, see control above)"
  echo "===== end configure flags ====="

  # The producer mozconfig asks for --enable-lto=cross. Assert configure agreed
  # rather than trusting the flag: a silently-dropped option produces a green
  # build whose numbers mean nothing, which is how the hardening arm went VOID.
  # The PW_SKIP_APORTS diagnostic path disables LTO on purpose, so it is exempt.
  if [[ "$PW_SKIP_APORTS" != "1" ]]; then
    if grep -qE '^MOZ_LTO[[:space:]]*=[[:space:]]*\S' "$AUTOCONF_MK"; then
      echo "  LTO reached configure ✓"
    else
      echo "ERROR: mozconfig asked for LTO but autoconf.mk has no MOZ_LTO" >&2
      exit 1
    fi
  fi
else
  echo "WARNING: no autoconf.mk at $AUTOCONF_MK — hardening flags unreportable" >&2
fi

# cbindgen 0.29.4 (Alpine edge) has a regression where impl-associated
# constants used in Rust array-size expressions (e.g. `[BudgetType;
# BudgetType::COUNT]`) get emitted as bare `[COUNT]` in the generated
# C++ header, breaking clang-22 compilation:
#   webrender_ffi_generated.h:6735:53: error: use of undeclared identifier 'COUNT'
# The header is regenerated on every `./mach build` invocation, so we
# patch it in-place BETWEEN mach's first pass (which generated it) and
# any retry. Fix is idempotent + narrow — targets only the specific
# BudgetType_VALUES + PRESSURE_COUNTERS + bytes_per_texture_of_type
# array bounds.
#
# The array size is `BudgetType::COUNT`. We DERIVE the real count from the
# header's OWN `BudgetType_VALUES[COUNT] = { ... }` initializer — a
# `[BudgetType; COUNT]` array holding exactly COUNT `BudgetType::` elements —
# rather than hardcoding it. A future Firefox bump that adds a BudgetType
# variant would still emit `[COUNT]`, and a hardcoded size would then silently
# under-size the array (no compile error, wrong runtime bound). Deriving from
# the emitted initializer is self-consistent (matches the elements cbindgen
# actually wrote) and independent of the Rust source's `const COUNT` form,
# which varies across revisions. If the initializer can't be found, FAIL LOUD
# instead of guessing.
FFI_HDR="/work/firefox-src/obj/dist/include/mozilla/webrender/webrender_ffi_generated.h"
if [[ "$mach_rc" != "0" && -f "$FFI_HDR" ]] && grep -q '\[COUNT\]' "$FFI_HDR"; then
  BUDGET_COUNT=$(awk '/BudgetType_VALUES\[COUNT\] = \{/ { print gsub(/BudgetType::/, "&"); exit }' "$FFI_HDR")
  if [[ -z "$BUDGET_COUNT" || "$BUDGET_COUNT" -lt 1 ]]; then
    echo "ERROR: cbindgen [COUNT] patch: could not derive BudgetType::COUNT from" >&2
    echo "       $FFI_HDR (BudgetType_VALUES initializer moved/reshaped?)." >&2
    echo "       Refusing to guess an array size — inspect the generated header." >&2
    exit 1
  fi
  echo "===== Patching webrender_ffi_generated.h — cbindgen bare-COUNT bug (COUNT=$BUDGET_COUNT) ====="
  sed -i "s/\[COUNT\]/[$BUDGET_COUNT]/g" "$FFI_HDR"
  echo "===== Retry ./mach build after webrender FFI patch ====="
  mach_rc=0
  ./mach build || mach_rc=$?
  echo "===== END ./mach build retry (rc=$mach_rc) ====="
fi

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

if [ -z "$DIST" ] && [ "$PW_SKIP_APORTS" == "1" ]; then
  # Packaging-free fallback, DIAGNOSTIC PATH ONLY: obj/dist/bin/ has the built
  # firefox binary + libxul.so + chrome/ + omni.ja, but NOT the packaged
  # layout — it is the raw build output, ~8700 files against a packaged
  # tree's ~130, and it carries test binaries like xpcshell.
  #
  # Gated on PW_SKIP_APORTS because it was written for that path and never
  # restricted to it. On 2026-08-27 a producer build whose `mach build package`
  # failed fell through to here, published 8730 files under a normal sha- tag
  # labelled "artifact OK", and killed all 20 conformance shards on
  # xpcshell's unresolved XRE_GetBootstrap. A build that cannot package must
  # not publish. See project_ff_cold_build_ships_unpackaged_tree.
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
  if [ "$pkg_rc" != "0" ] && [ "$PW_SKIP_APORTS" != "1" ]; then
    echo "ERROR: './mach build package' failed (rc=$pkg_rc) and there is no" >&2
    echo "packaged tree to ship. The obj/dist/bin fallback is diagnostic-only" >&2
    echo "and deliberately does not rescue a producer build — it would publish" >&2
    echo "the raw build output (~8700 files incl. xpcshell) under a normal tag." >&2
    echo "Fix packaging; see project_ff_cold_build_ships_unpackaged_tree." >&2
  fi
  echo "ERROR: mach build rc=$mach_rc, package rc=$pkg_rc, no firefox binary at '$DIST'" >&2
  echo "obj/ contents:" >&2
  find obj* -maxdepth 3 -type d 2>/dev/null | head -50 >&2 || true
  echo "obj/dist contents:" >&2
  ls -la obj*/dist 2>/dev/null || true
  exit 1
fi
echo "===== Built: $SRC/$DIST (mach rc=$mach_rc, package rc=$pkg_rc; artifact OK) ====="

# libxul's .text size is the cheapest evidence that a codegen-level option
# (LTO here, hardening before it) actually changed the artifact: an arm whose
# .text matches the baseline byte-for-byte varied nothing. Non-LTO baseline for
# firefox 153.0 is 118 846 320 B. Read AFTER the build is confirmed: the
# cbindgen two-pass means the first ./mach build fails by design, and at that
# point there is no libxul to measure.
XUL="$SRC/obj/dist/bin/libxul.so"
if [[ -r "$XUL" ]] && command -v readelf >/dev/null; then
  echo "===== libxul .text ====="
  readelf -S "$XUL" | grep -A1 '\.text ' | sed 's/^/  /' || echo "  (no .text section)"
  echo "===== end libxul .text ====="
else
  echo "WARNING: libxul .text unreportable ($XUL / readelf)" >&2
fi
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

# PW SDK prefs — Ubuntu FF ships them at these exact paths inside the
# packaged dist tree. The earlier `cp -a "$PW/preferences/." browser/app/profile/`
# at line 175 puts them in the SOURCE tree where they get dropped during
# packaging. Copy into the packaged DIST here so they survive to the artifact.
# Missing these means `dom.security.https_first=false` never applies, PW's
# proxy filter never attaches, and every proxy / client-cert / third-party
# cookie test fails. Diagnosed 2026-07-09 via agent-3 investigation.
if [[ -d "$PW/preferences" ]]; then
  echo "===== Copying PW prefs into DIST (client-cert + proxy fix) ====="
  mkdir -p /work/firefox-dist/browser/defaults/preferences
  [[ -f "$PW/preferences/00-playwright-prefs.js" ]] && \
    cp "$PW/preferences/00-playwright-prefs.js" /work/firefox-dist/browser/defaults/preferences/
  [[ -f "$PW/preferences/playwright.cfg" ]] && \
    cp "$PW/preferences/playwright.cfg" /work/firefox-dist/
  # Headless musl FF's LookAndFeel defaults pointer/hover to coarse/none, so
  # `(hover: hover)` + `(pointer: fine)` don't match on the default desktop
  # context (Ubuntu FF reports fine+hover by default). PW forces this for chromium
  # via --blink-settings but has no firefox equivalent → set FF's own pref
  # (6 = eFine|eHover) as a baked default so the artifact matches Ubuntu FF.
  printf 'pref("ui.primaryPointerCapabilities", 6);\npref("ui.allPointerCapabilities", 6);\n' \
    > /work/firefox-dist/browser/defaults/preferences/01-alpine-pointer.js
fi

# Self-contained-bundle step (ldd-walk + RPATH=$ORIGIN + ICU data). Shared
# with apply-and-build-iter.sh so the iter path also produces a correctly-
# bundled artifact. See bundle-dist.sh for the rationale per excluded lib.
bash "$WORK/firefox/scripts/bundle-dist.sh" /work/firefox-dist
