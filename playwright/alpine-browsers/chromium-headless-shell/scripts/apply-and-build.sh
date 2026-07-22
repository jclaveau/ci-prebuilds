#!/usr/bin/env bash
# Main build pipeline for musl chrome-headless-shell.
#
# Inputs (from versions.env + fetch-pw-browsers-json.sh):
#   PW_VERSION                          — sole hand-edited pin
#   CHROMIUM_HEADLESS_SHELL_REVISION    — derived; baked into artifact tag
#   CHROMIUM_HEADLESS_SHELL_VERSION     — derived; chosen Chromium source tag
#   ALPINE_APORTS_CHROMIUM_REF          — aports SHA whose APKBUILD pkgver matches the above
#
# Diagnostic env vars (default off — same idempotent-block pattern as Firefox):
#   PW_CHROMIUM_SKIP_APORTS=1           — don't apply aports musl patches (glibc-debug path)
#   PW_CHROMIUM_ENABLE_DEBUG=1          — is_debug=true, dcheck_always_on=true; for validation track
#
# Output: /work/chromium-dist/{chrome-headless-shell, *.so, locales/, …} — a
# runnable headless_shell tree, ready for stage-cache-layout.sh to rename into
# PW's expected directory shape.

set -euo pipefail

WORK="${1:?usage: apply-and-build.sh <work_dir>}"
APORTS="$WORK/aports"
SCRIPTS_DIR="$WORK/chromium-headless-shell/scripts"

# 1. Read PW_VERSION + ALPINE_APORTS_CHROMIUM_REF from versions.env, then derive
#    the chromium pins from PW's browsers.json. fetch-pw-browsers-json.sh emits
#    env-var assignments on stdout; eval them into our scope.
set -a
. "$WORK/versions.env"
eval "$("$SCRIPTS_DIR/fetch-pw-browsers-json.sh" chromium-headless-shell)"
set +a

CHS_REV="${CHROMIUM_HEADLESS_SHELL_REVISION:?derivation failed}"
CHS_VER="${CHROMIUM_HEADLESS_SHELL_VERSION:?derivation failed}"
echo "===== build: PW_VERSION=$PW_VERSION CHS_REV=$CHS_REV CHS_VER=$CHS_VER ====="

: "${PW_CHROMIUM_SKIP_APORTS:=0}"
: "${PW_CHROMIUM_ENABLE_DEBUG:=0}"
truthy() { case "${1,,}" in 1|true|yes|on) echo 1 ;; *) echo 0 ;; esac; }
PW_CHROMIUM_SKIP_APORTS=$(truthy "$PW_CHROMIUM_SKIP_APORTS")
PW_CHROMIUM_ENABLE_DEBUG=$(truthy "$PW_CHROMIUM_ENABLE_DEBUG")
echo "Flags: PW_CHROMIUM_SKIP_APORTS=$PW_CHROMIUM_SKIP_APORTS PW_CHROMIUM_ENABLE_DEBUG=$PW_CHROMIUM_ENABLE_DEBUG"

# 2. Sanity: aports' APKBUILD pkgver must match CHS_VER, otherwise the patches
#    were authored against a different Chromium and may not apply.
if [[ "$PW_CHROMIUM_SKIP_APORTS" != "1" ]]; then
  [[ -f "$APORTS/APKBUILD" ]] || { echo "missing $APORTS/APKBUILD" >&2; exit 1; }
  APORTS_PKGVER=$(awk -F= '$1=="pkgver"{gsub(/"/,"",$2); print $2; exit}' "$APORTS/APKBUILD")
  if [[ "$APORTS_PKGVER" != "$CHS_VER" ]]; then
    echo "ERROR: aports pkgver=$APORTS_PKGVER but PW pins CHS_VER=$CHS_VER" >&2
    echo "  Bump ALPINE_APORTS_CHROMIUM_REF in versions.env to a commit where pkgver matches." >&2
    exit 2
  fi
  echo "  aports pkgver matches CHS_VER ✓"
fi

# 3. Source tree.
SRC="$WORK/chromium-src/chromium-${CHS_VER}"
if [[ ! -d "$SRC" ]]; then
  echo "ERROR: expected source tree at $SRC (fetch-chromium-src.sh ran?)" >&2
  exit 3
fi
cd "$SRC"

# 3a. Persistent obj/ cache. BuildKit cache mounts can't templatize their
# target path, so the Dockerfile mounts at the stable /work/chromium-out and
# we symlink $SRC/out → there at runtime. Ninja then writes its obj graph
# into the cache mount; subsequent runs reuse the dep state and most of the
# .o files (instead of re-discovering 38k actions each iteration).
#
# sccache caches the compiler invocations per-file, but ninja still has to
# walk + dispatch the full action graph each time without this. Symlinking
# out/ to a persistent mount means ninja sees an already-populated obj tree
# and only rebuilds what changed.
CACHE_OUT="/work/chromium-out"
if [[ -d "$CACHE_OUT" ]]; then
  rm -rf out
  ln -sf "$CACHE_OUT" out
  echo "  out/ symlinked to $CACHE_OUT (BuildKit cache mount)"
else
  echo "  WARN: $CACHE_OUT not present (cache mount missing?) — running without obj cache" >&2
fi

# 4. Apply aports' musl patches. Skip arch-specific ones (riscv, ppc, etc.) —
#    amd64 only for now. aports' APKBUILD has a `prepare()` shell function that
#    enumerates patches; we mimic it but skip what we don't need.
if [[ "$PW_CHROMIUM_SKIP_APORTS" == "1" ]]; then
  echo "===== SKIP aports patches (PW_CHROMIUM_SKIP_APORTS=1) ====="
else
  echo "===== Apply aports musl patches ====="
  # All .patch files in aports/ — aports' APKBUILD generally applies them in
  # alphabetical order via the source= array. Honor the same order.
  for p in $(ls -1 "$APORTS"/*.patch 2>/dev/null | sort); do
    name=$(basename "$p")
    # Skip arch-specific patches we don't need on amd64.
    case "$name" in
      *riscv*|*ppc*|*loong*) echo "  skip $name (non-amd64)"; continue ;;
    esac
    echo "  apply $name"
    patch -p1 --forward -i "$p" || {
      echo "  WARN: $name did not apply cleanly; continuing — chromium may still build" >&2
    }
  done
fi

# 4a. Apply copium patches — aports' chromium pulls a separate patch bundle
#     from codeberg.org/selfisekai/copium that handles all the musl + upstream-
#     clang adjustments aports doesn't ship as standalone .patch files in
#     community/chromium/. Reads aports' _copium_patches list + _copium_tag
#     directly from APKBUILD so versions track. Without these we get errors
#     like "use of undeclared identifier cntrl" in libc++ headers (the cr147
#     is-musl-libcxx patch fixes it), unknown clang flags (cr146), etc.
echo "===== Fetch + apply copium patches ====="
if [[ -f "$APORTS/APKBUILD" ]]; then
  COPIUM_TAG=$(awk -F= '$1=="_copium_tag"{gsub(/"/,"",$2); print $2; exit}' "$APORTS/APKBUILD")
  COPIUM_PATCHES=$(awk '
    /^_copium_patches="/{flag=1; next}
    flag && /"/{flag=0; next}  # closing " may have leading whitespace
    flag {gsub(/^[ \t]+/,""); gsub(/[ \t]+$/,""); if ($0!="") print}
  ' "$APORTS/APKBUILD")
  COPIUM_DIR="$WORK/copium"
  if [[ ! -d "$COPIUM_DIR" ]]; then
    mkdir -p "$COPIUM_DIR"
    echo "  fetch copium-${COPIUM_TAG}.tar.gz from codeberg"
    # Codeberg occasionally has sustained 503 outages (runs 28305464435,
    # 28306163932, 28306825928, 28307474833). Retry up to 20 × 60s = ~20min
    # to ride out the outage. No alternate mirror exists — copium is
    # codeberg-hosted only (gitlab.alpinelinux.org/aports's APKBUILD pulls
    # the same URL); searched github + alpine distfiles, both 404.
    curl -fsSL --retry 20 --retry-delay 60 --retry-all-errors \
      "https://codeberg.org/selfisekai/copium/archive/${COPIUM_TAG}.tar.gz" \
      | tar -xz -C "$COPIUM_DIR" --strip-components=1
  fi
  for p in $COPIUM_PATCHES; do
    if [[ -f "$COPIUM_DIR/$p" ]]; then
      echo "  apply $p"
      patch -p1 --forward -i "$COPIUM_DIR/$p" || {
        echo "  WARN: $p did not apply cleanly" >&2
      }
    else
      echo "  MISS: $p not in copium tag $COPIUM_TAG" >&2
    fi
  done
fi

# 4b. Musl/clang22 host-tool link fix — chromium 148 host tools (e.g.
#     character_data_generator) reference `base::debug::StackTrace::
#     OutputToStreamWithPrefixImpl` but our libbase.a doesn't carry the
#     symbol. Most likely a copium patch (cr147-is-musl-libcxx) flips a
#     build-conditional that excludes the real impl from stack_trace_posix.cc.
#     Without source access we can't pinpoint the exact #ifdef; append a
#     weak-symbol stub to base/debug/stack_trace.cc so the link resolves.
#     The real impl, if compiled, wins over the weak fallback.
#     See ci-prebuilds run 28255952380 + task #15.
echo "===== Musl host-tool link fix: append weak StackTrace::OutputToStreamWithPrefixImpl stub ====="
if grep -q '^// musl-host-tool-link-fix$' base/debug/stack_trace.cc 2>/dev/null; then
  echo "  already patched (sentinel found)"
else
  cat >> base/debug/stack_trace.cc <<'STACK_TRACE_EOF'

// musl-host-tool-link-fix
// Weak fallback for OutputToStreamWithPrefixImpl. Some musl/clang22 build
// paths in chromium 148 emit libbase.a without the real impl (compiled out
// of stack_trace_posix.cc), causing host-tool links to fail with
// `undefined symbol`. Weak storage class means: if the real impl is
// present, it wins; if not, this no-op stub keeps the link alive. Host
// tools (character_data_generator, transport_security_state_generator)
// only call OutputToStreamWithPrefix during crash paths, so silently
// dropping the prefix-string output is acceptable for them.
namespace base::debug {
__attribute__((weak))
void StackTrace::OutputToStreamWithPrefixImpl(
    std::ostream* /*os*/, base::cstring_view /*prefix_string*/) const {}
}  // namespace base::debug
STACK_TRACE_EOF
  echo "  appended weak stub"
fi

# 4c. Aports' prepare() does several bootstrap steps Chromium's build expects
#     but our environment doesn't have. Replicate the ones headless_shell
#     actually needs. Skipping the headless-irrelevant ones (usb.ids sed,
#     OFFICIAL_BUILD sed, replace_gn_files.py for system libs — we keep
#     Chromium's bundled libs).
echo "===== Aports prepare() bootstrap ====="

# (a) Strip embedded binaries from third_party/. Chromium's source tarball
# contains pre-built binaries in various third_party/ dirs (M127+). They're
# usually CIPD-fetched placeholders that conflict with our system-provided
# tools or simply waste space. scanelf finds them; rm cleans.
if command -v scanelf >/dev/null; then
  echo "  scanelf: removing embedded ELF binaries from source tree"
  scanelf -RA -F "%F" . 2>/dev/null | while read -r elf; do
    rm -f "$elf"
  done
fi

# (b) test_fonts/test_fonts: aports replaces this with a self-symlink to
# avoid Chromium's test_fonts build action that downloads more data we don't
# need. Headless_shell doesn't run tests but the build graph still includes
# the action.
if [[ -d third_party/test_fonts/test_fonts ]]; then
  rmdir third_party/test_fonts/test_fonts 2>/dev/null
  ln -sf ../../../ third_party/test_fonts/test_fonts
fi

# (c) node binary symlink. Chromium ships a CIPD placeholder; force-overwrite.
mkdir -p third_party/node/linux/node-linux-x64/bin
ln -sfv /usr/bin/node third_party/node/linux/node-linux-x64/bin/node

# (d) esbuild: replace BOTH the standalone binary AND the node_modules JS host.
# Chromium pins 0.25.1; alpine apk ships 0.27.1 — if only the binary is
# symlinked, the host JS hits a version-mismatch RuntimeError. Aports replaces
# both halves in prepare().
if [[ -d third_party/devtools-frontend/src/third_party/esbuild ]]; then
  ln -sfv /usr/bin/esbuild third_party/devtools-frontend/src/third_party/esbuild/esbuild
fi
if [[ -d third_party/devtools-frontend/src/node_modules/esbuild ]]; then
  rm -rf third_party/devtools-frontend/src/node_modules/esbuild
  ln -sfv /usr/lib/node_modules/esbuild third_party/devtools-frontend/src/node_modules/esbuild
fi

# (e) rollup: Chromium's devtools-frontend bundles rollup at a specific
# version. Alpine's apk doesn't ship @rollup/wasm-node, so aports fetches the
# npm tarball at the version pinned via _rollup in APKBUILD. Without this,
# the next ninja action (devtools-frontend bundles) will fail like esbuild did.
if [[ -d third_party/devtools-frontend/src/node_modules ]] && [[ -f "$APORTS/APKBUILD" ]]; then
  ROLLUP_VER=$(awk -F= '$1=="_rollup"{gsub(/"/,"",$2); print $2; exit}' "$APORTS/APKBUILD")
  if [[ -n "$ROLLUP_VER" ]]; then
    ROLLUP_TGZ="$WORK/rollup-wasm-${ROLLUP_VER}.tgz"
    if [[ ! -f "$ROLLUP_TGZ" ]]; then
      echo "  fetch @rollup/wasm-node@${ROLLUP_VER} from npm"
      curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
        "https://registry.npmjs.org/@rollup/wasm-node/-/wasm-node-${ROLLUP_VER}.tgz" -o "$ROLLUP_TGZ"
    fi
    rm -rf third_party/devtools-frontend/src/node_modules/rollup
    mkdir third_party/devtools-frontend/src/node_modules/rollup
    tar -xf "$ROLLUP_TGZ" --strip-components=1 \
      -C third_party/devtools-frontend/src/node_modules/rollup
    echo "  rollup-wasm extracted ($(ls third_party/devtools-frontend/src/node_modules/rollup | wc -l) files)"
  fi
fi

# (f) gperf symlink (CIPD placeholder, same shape).
if [[ -d third_party/gperf/cipd/bin ]]; then
  ln -sfv /usr/bin/gperf third_party/gperf/cipd/bin/gperf
fi

# (g) libxml malloc/free fix — aports replaces xmlMalloc/xmlFree → malloc/free
# in blink + libxml chromium glue. See crbug.com/893950. Without it, builds
# error against libxml's symbol export differences with the system libxml.
echo "  libxml malloc/free fix"
sed -i -e 's/\<xmlMalloc\>/malloc/g' -e 's/\<xmlFree\>/free/g' \
  third_party/blink/renderer/core/xml/*.cc \
  third_party/blink/renderer/core/xml/parser/xml_document_parser.cc \
  third_party/libxml/chromium/*.cc 2>/dev/null || true

# (h) Replace bundled-lib build files with system-library equivalents. Aports
# does this so Chromium uses Alpine's system fontconfig/freetype/harfbuzz/etc.
# rather than its bundled forks (which assume glibc — bundled fontconfig uses
# `initstate_r`/`random_r` which don't exist in musl).
#
# `build/linux/unbundle/replace_gn_files.py` is upstream Chromium's tool for
# this. It rewrites the BUILD.gn for each named lib to source-link from
# `build/linux/unbundle/<lib>.gn` instead of `third_party/<lib>/BUILD.gn`.
echo "===== Replace bundled libs with system equivalents ====="
USE_SYSTEM_LIBS=(
  brotli
  crc32c
  dav1d
  double-conversion
  # ffmpeg + flac REMOVED from system-libs 2026-07-13 — alpine SONAME skew:
  #   - flac: alpine:edge shipped flac 1.5.0 (libFLAC.so.14) which drops the
  #     encoder_get_* public exports. Chromium 148 links against them; ld.so
  #     runtime: "Error relocating: FLAC__stream_encoder_get_sample_rate:
  #     symbol not found".
  #   - ffmpeg: alpine:edge ships ffmpeg 8.x (libavformat.so.62), alpine:3.22
  #     runtime image ships ffmpeg 6.x (libavformat.so.60). SONAME mismatch
  #     → runtime "Error relocating chrome-headless-shell: av_strerror:
  #     symbol not found". (Runner base is 3.22 because alpine:edge chromium
  #     apk needs libFLAC.so.12 — see conformance/build-runner.sh comment.)
  # Use chromium's bundled third_party/{flac,ffmpeg}/ instead — matched to
  # chromium's link expectations.
  fontconfig
  freetype
  harfbuzz
  highway
  libdrm
  libjpeg
  libwebp
  libxml
  libxslt
  openh264
  opus
  zlib
  zstd
)
if [[ -x build/linux/unbundle/replace_gn_files.py ]] || [[ -f build/linux/unbundle/replace_gn_files.py ]]; then
  python3 build/linux/unbundle/replace_gn_files.py \
    --system-libraries "${USE_SYSTEM_LIBS[@]}" \
    || { echo "  replace_gn_files.py failed; some libs may stay bundled" >&2; }
else
  echo "  WARN: build/linux/unbundle/replace_gn_files.py missing — skipping" >&2
fi

# 5. Configure GN. Compose: aports' default args (if its APKBUILD exports any
#    via a gn_args block) + our overlay (args.gn.overlay) + diagnostic overrides.
echo "===== Configure GN ====="

# Chromium's Rust build path enforces a list of known target triples (defined
# in build/rust/known-target-triples.txt). The Alpine clang reports its target
# as `x86_64-alpine-linux-musl`, which upstream doesn't list. Aports handles
# this with a shell-side append in its APKBUILD's _configure() — replicate.
CTARGET="${CTARGET:-$(cc -dumpmachine)}"
if ! grep -qx "$CTARGET" build/rust/known-target-triples.txt 2>/dev/null; then
  echo "  appending $CTARGET to build/rust/known-target-triples.txt"
  echo "$CTARGET" >> build/rust/known-target-triples.txt
fi

# clang_base_path GN arg points at where chromium will look for system clang.
# aports uses /usr/lib/llvm$_llvmver — read the same _llvmver from aports'
# APKBUILD so our build matches the version of clang the patches expect.
if [[ -f "$APORTS/APKBUILD" ]]; then
  LLVMVER=$(awk -F= '$1=="_llvmver"{gsub(/[^0-9]/,"",$2); print $2; exit}' "$APORTS/APKBUILD")
  CLANG_BASE="/usr/lib/llvm${LLVMVER:-22}"
else
  CLANG_BASE="/usr/lib/llvm22"  # fallback; alpine:edge currently ships llvm22
fi
echo "  CLANG_BASE=$CLANG_BASE  CTARGET=$CTARGET"

# Chromium's unbundle toolchain at //build/toolchain/linux/unbundle:default
# reads AR/CC/CXX/NM from env to find the real binaries. Without these the
# ninja command template emits a bare `-MD -MF …` and /bin/sh tries to
# interpret `-M` as a shell flag (busybox ash doesn't have one) and fails
# with `illegal option -M`. aports' APKBUILD exports these explicitly; we
# mirror.
export AR="$CLANG_BASE/bin/llvm-ar"
export NM="$CLANG_BASE/bin/llvm-nm"
export CC="$CLANG_BASE/bin/clang"
export CXX="$CLANG_BASE/bin/clang++"
echo "  AR=$AR  CC=$CC  CXX=$CXX  NM=$NM"

# Chromium's build scripts pass -Z nightly-only rustc flags (codegen-units,
# panic-abort-tests, etc.). Stable rust rejects them with "1 nightly option
# were parsed". RUSTC_BOOTSTRAP=1 is the classic escape hatch — tells stable
# rustc to accept -Z flags. Aports' chromium APKBUILD sets the same.
export RUSTC_BOOTSTRAP=1
echo "  RUSTC_BOOTSTRAP=1 (allow -Z flags on stable rust)"

# VARIANT (headless|headed) selects the out dir, args overlay + ninja target.
. "$WORK/chromium-headless-shell/scripts/variant-config.sh"
OUT_DIR="$VARIANT_OUT_DIR"
mkdir -p "$OUT_DIR"

{
  cat "$WORK/chromium-headless-shell/$VARIANT_OVERLAY"
  echo ""
  echo "# Injected at build time"
  echo "clang_base_path = \"$CLANG_BASE\""
  echo "clang_version = \"${LLVMVER:-22}\""
  echo ""
  echo "# Diagnostic-flag overrides"
  if [[ "$PW_CHROMIUM_ENABLE_DEBUG" == "1" ]]; then
    echo "is_debug = true"
    echo "dcheck_always_on = true"
    echo "symbol_level = 1"
  fi
} > "$OUT_DIR/args.gn"

echo "  args.gn:"
sed 's/^/    /' "$OUT_DIR/args.gn"

# Chromium's source tarball ships `buildtools/linux64/gn` as a depot_tools/CIPD
# placeholder, not a usable binary — running it returns exit 127. We bring our
# own `gn` from the alpine apk install (community/gn pkg). Prefer system gn
# unconditionally; only fall back to the vendored path if it ever materializes.
if command -v gn >/dev/null; then
  GN="$(command -v gn)"
elif [[ -x "buildtools/linux64/gn" ]] && file "buildtools/linux64/gn" | grep -q ELF; then
  GN="buildtools/linux64/gn"
else
  echo "ERROR: no usable gn binary (need apk add gn)" >&2
  exit 4
fi
echo "  using gn at: $GN"

"$GN" gen "$OUT_DIR"

# 6. Build. headless_shell is the canonical chrome-headless-shell binary
#    target. ninja parallelism caps to the runner's CPU count automatically.
#
# PW_CHROMIUM_SKIP_NINJA=1 splits ninja into its own Dockerfile RUN(s) so each
# partial-build layer caches independently (GHA hosted runner 6h cap exceeds a
# single-RUN cold build; multi-RUN with cache-to=registry lets later iters
# resume from the last completed layer). When set, this script ends here.
if [[ "${PW_CHROMIUM_SKIP_NINJA:-0}" == "1" ]]; then
  echo "===== SKIP ninja (PW_CHROMIUM_SKIP_NINJA=1; Dockerfile owns ninja) ====="
  exit 0
fi
echo "===== START ninja $VARIANT_TARGET ====="
ninja_rc=0
ninja -C "$OUT_DIR" -j "${NINJA_JOBS:-$(nproc)}" $VARIANT_TARGET || ninja_rc=$?
echo "===== END ninja $VARIANT_TARGET (rc=$ninja_rc) ====="

if [[ $ninja_rc -ne 0 ]]; then
  echo "ERROR: ninja failed with rc=$ninja_rc" >&2
  exit 5
fi

# 7. Locate the output. Chromium's headless_shell target produces:
#    out/headless/headless_shell (binary)
#    out/headless/icudtl.dat, *.bin, headless_lib_data/, locales/, …
BIN="$OUT_DIR/headless_shell"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: expected $BIN to exist after ninja" >&2
  ls -la "$OUT_DIR" | head -20
  exit 6
fi

# 8. Invariant assertion — the binary must report the PW-expected browserVersion.
echo "===== Version invariant check ====="
ACTUAL_VER=$("$BIN" --version 2>&1 || true)
echo "  $BIN --version → $ACTUAL_VER"
if ! echo "$ACTUAL_VER" | grep -q "$CHS_VER"; then
  echo "ERROR: binary version does not contain expected $CHS_VER" >&2
  exit 7
fi
echo "  version matches PW's pinned $CHS_VER ✓"

# 9. Stage to /work/chromium-dist/ for the artifact stage.
# File list mirrors what PW's official chromium-headless-shell-linux64
# ships under mcr.microsoft.com/playwright — verified by ls against
# v1.60.0-noble. Missing any of these produces:
#   - headless_lib_data.pak absent → UA stylesheet not applied → every
#     <div>/<p>/<input> reports display:inline + rect.width=0 → PW auto-wait
#     fails "element is not visible" (see project_pw_conformance_visibility_cluster).
#   - locales/ absent → i18n init warning + a few tests skip.
#   - libvulkan.so.1 + vk_swiftshader_icd.json absent → GPU fallback broken.
DIST="$WORK/chromium-dist"
mkdir -p "$DIST"
cp -a "$BIN" "$DIST/"
for f in icudtl.dat snapshot_blob.bin v8_context_snapshot.bin \
         headless_command_resources.pak headless_lib_data.pak headless_lib_strings.pak \
         vk_swiftshader_icd.json; do
  [[ -f "$OUT_DIR/$f" ]] && cp -a "$OUT_DIR/$f" "$DIST/"
done
for d in locales hyphen-data; do
  [[ -d "$OUT_DIR/$d" ]] && cp -a "$OUT_DIR/$d" "$DIST/"
done

# Bundled .so + .so.N shared libs (libEGL.so, libGLESv2.so, libvk_swiftshader.so,
# libvulkan.so.1). Match .so and .so.<any> — glob *.so does NOT match libvulkan.so.1.
find "$OUT_DIR" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) -exec cp -a {} "$DIST/" \;

echo "===== DIST staged at $DIST ====="
ls -lh "$DIST" | head -20

echo "===== Build complete: CHS_REV=$CHS_REV CHS_VER=$CHS_VER ====="
