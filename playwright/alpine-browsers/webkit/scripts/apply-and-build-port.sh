#!/usr/bin/env bash
# Idempotent + progressive per-port WebKit build.
#
# Reads PORT env (WPE or GTK). Runs phases gated on sentinel files in the
# inherited image filesystem:
#
#   1. cmake configure   — until $BUILD_DIR/CMakeCache.txt exists
#   2. ninja MiniBrowser — until $BUILD_DIR/bin/MiniBrowser exists
#                          (bounded by STAGE_NINJA_TIMEOUT, default 4.5h)
#   3. stage + bundle    — until /work/minibrowser-${port-lower}-dist has the
#                          binary + bundled .so deps + RPATH=$ORIGIN
#
# Each invocation completes as much as fits in the budget then exits 0
# leaving state in image layers for the next stage to FROM. Same script
# is used by the checkpoint job (first invocation; BASE_IMAGE = source-prep)
# and by every resume job (BASE_IMAGE = previous stage's image).
#
# Usage: apply-and-build-port.sh <work_dir>
# Env:
#   PORT                  WPE or GTK
#   ENABLE_JIT            ON (default) or OFF
#   STAGE_NINJA_TIMEOUT   seconds (default 16200 = 4.5h)

set -euo pipefail

WORK="${1:?usage: apply-and-build-port.sh <work_dir>}"
PW="$WORK/pw-webkit"
OVERLAY="$WORK/webkit/cmake-flags.overlay"
SRC="$WORK/webkit-src"

: "${PORT:?PORT must be set (WPE or GTK)}"
case "$PORT" in
  WPE|GTK) ;;
  *) echo "ERROR: PORT must be WPE or GTK (got: $PORT)" >&2; exit 1 ;;
esac

PORT_LOWER=$(echo "$PORT" | tr '[:upper:]' '[:lower:]')
BUILD_DIR="$SRC/WebKitBuild/$PORT/Release"
DIST="$WORK/minibrowser-${PORT_LOWER}-dist"

[[ -d "$SRC" ]] || { echo "missing $SRC — source-prep didn't set up the tree" >&2; exit 1; }
[[ -f "$PW/UPSTREAM_CONFIG.sh" ]] || { echo "missing $PW/UPSTREAM_CONFIG.sh" >&2; exit 1; }
[[ -f "$OVERLAY" ]] || { echo "missing $OVERLAY" >&2; exit 1; }

echo "===== apply-and-build-port: PORT=$PORT BUILD_DIR=$BUILD_DIR DIST=$DIST ====="

: "${ENABLE_JIT:=ON}"
: "${STAGE_NINJA_TIMEOUT:=16200}"
export ENABLE_JIT
echo "Flags: ENABLE_JIT=$ENABLE_JIT STAGE_NINJA_TIMEOUT=${STAGE_NINJA_TIMEOUT}s"

# Per-script time budget. Each phase consumes the remainder; if cmake
# configure runs quickly, ninja gets the bulk.
STAGE_DEADLINE=$(( $(date +%s) + STAGE_NINJA_TIMEOUT ))
remaining_seconds() {
  local now
  now=$(date +%s)
  local r=$(( STAGE_DEADLINE - now ))
  (( r > 60 )) || r=60
  echo "$r"
}

# shellcheck disable=SC1090
. "$OVERLAY"

export SCCACHE_DIR=/root/.cache/sccache
export SCCACHE_CACHE_SIZE=16G
mkdir -p "$SCCACHE_DIR"
sccache --start-server 2>/dev/null || true
sccache --show-stats || true

export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"
export AR="${AR:-llvm-ar}"
export NM="${NM:-llvm-nm}"
export RANLIB="${RANLIB:-llvm-ranlib}"

: "${CFLAGS:=-O2 -pipe -g1}"
: "${CXXFLAGS:=$CFLAGS}"
: "${LDFLAGS:=-fuse-ld=lld}"
export CFLAGS CXXFLAGS LDFLAGS

ulimit -n 4096 || true

cd "$SRC"

# Phase 1 — cmake configure (one-shot per port).
if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
  echo "===== Phase 1: cmake configure PORT=$PORT ====="
  mkdir -p "$BUILD_DIR"
  cmake -GNinja \
    -DPORT="$PORT" \
    -S "$SRC" \
    -B "$BUILD_DIR" \
    "${CMAKE_SHARED_FLAGS[@]}"
  echo "===== Phase 1 complete: PORT=$PORT configured ====="
else
  echo "===== Phase 1 already done: $BUILD_DIR/CMakeCache.txt exists ====="
fi

# Phase 2 — ninja MiniBrowser (progressive across resumes).
if [[ ! -f "$BUILD_DIR/bin/MiniBrowser" ]]; then
  # Populate the forwarding headers before anything compiles.
  #
  # WebKit 4d05d732 split JSC's JIT into its own subtarget
  # (WEBKIT_DEFINE_SUBTARGET_WITH_PREFIX(JavaScriptCore JavaScriptCoreJIT ...)),
  # and that subtarget's precompiled header does not depend on
  # JavaScriptCore_CopyPrivateHeaders. With a cold cache and full parallelism the
  # PCH therefore starts before the headers are symlinked and dies on
  #   B3ValueRep.h:32:10: fatal error: 'JavaScriptCore/FPRInfo.h' file not found
  # even though ninja generates that header seconds later (run 32232319190,
  # 26 minutes in, unit 6601/8797). The old base had no such subtarget, which is
  # why this only appeared when the base moved.
  #
  # Building the copy targets first is deterministic — unlike lowering -j or
  # retrying, which only make the race less likely. Each is a no-op on resume
  # rounds, and `|| true` keeps this harmless if a target is renamed upstream:
  # the real build below still gates the round.
  for hdr_target in WTF_CopyHeaders bmalloc_CopyHeaders JavaScriptCore_CopyPrivateHeaders; do
    echo "--- pre-building $hdr_target ---"
    cmake --build "$BUILD_DIR" --target "$hdr_target" || \
      echo "note: $hdr_target not present in this WebKit revision — skipping"
  done

  echo "===== Phase 2: ninja PORT=$PORT (timeout: $(remaining_seconds)s) ====="
  rc=0
  # BusyBox `timeout` syntax: -s SIG SECS PROG; no `s` suffix.
  timeout -s TERM "$(remaining_seconds)" \
    cmake --build "$BUILD_DIR" --target MiniBrowser || rc=$?
  echo "Phase 2: ninja PORT=$PORT exit rc=$rc"
  sccache --show-stats || true
  LAST_STEP=$(tac "$BUILD_DIR/.ninja_log" 2>/dev/null | awk -F'\t' 'NR==1 {print}' || echo "(none)")
  echo "ninja last log line: $LAST_STEP"
  if [[ ! -f "$BUILD_DIR/bin/MiniBrowser" ]]; then
    # Only a timeout kill earns a resume. Any other rc means the compile itself
    # failed, and resuming just burns another round on the same error: a
    # duplicate enumerator took four rounds to surface as "wpe MiniBrowser
    # missing" in finalize's Tier-1, with every round green. 143 = BusyBox
    # timeout's SIGTERM, 124 = GNU coreutils.
    if [[ "$rc" != 143 ]] && [[ "$rc" != 124 ]]; then
      echo "ERROR: ninja PORT=$PORT failed with rc=$rc (not a timeout) and built no MiniBrowser" >&2
      exit 1
    fi
    echo "===== Phase 2 incomplete (timed out); next resume continues PORT=$PORT ====="
    mkdir -p "$DIST"
    exit 0
  fi
  echo "===== Phase 2 complete: $PORT MiniBrowser built ====="
else
  echo "===== Phase 2 already done: $BUILD_DIR/bin/MiniBrowser exists ====="
fi

# Phase 2.5 — injected bundle (MODULE library loaded by WPEWebProcess at runtime).
# Not a transitive dep of MiniBrowser, so `ninja MiniBrowser` skips it. Build
# explicitly; per-port target names. Idempotent via marker file.
case "$PORT" in
  WPE)  BUNDLE_TARGETS="WPEInjectedBundle" ;;
  GTK)  BUNDLE_TARGETS="webkitgtkinjectedbundle webkit2gtkinjectedbundle" ;;
  *)    BUNDLE_TARGETS="" ;;
esac
BUNDLE_MARKER="$BUILD_DIR/.injected-bundle-built"
if [[ -n "$BUNDLE_TARGETS" && ! -f "$BUNDLE_MARKER" ]]; then
  echo "===== Phase 2.5: ninja injected bundle PORT=$PORT ====="
  for tgt in $BUNDLE_TARGETS; do
    echo "--- ninja --target $tgt ---"
    cmake --build "$BUILD_DIR" --target "$tgt" 2>&1 || \
      echo "ninja target $tgt: skipped (not present in this WebKit revision)"
  done
  touch "$BUNDLE_MARKER"
  echo "===== Phase 2.5 complete ====="
else
  echo "===== Phase 2.5 already done or no targets ====="
fi

# Phase 3 — stage + bundle. Layout: <dist>/MiniBrowser + <dist>/*.so (FLAT)
# matching PW's published artifact contract. pw_run.sh resolves
# `$SCRIPT_PATH/$MINIBROWSER_FOLDER/MiniBrowser` — no bin/ subdir.
# Keep sys/lib/ (PW's contract; system lib override path, normally empty here).
if [[ ! -f "$DIST/MiniBrowser" ]]; then
  echo "===== Phase 3: stage + bundle PORT=$PORT ====="
  mkdir -p "$DIST/sys/lib"

  bin=$(find "$BUILD_DIR/bin" -maxdepth 1 -type f -name 'MiniBrowser' 2>/dev/null | head -1)
  if [[ -z "$bin" ]]; then
    bin=$(find "$BUILD_DIR" -maxdepth 4 -type f -name 'MiniBrowser' -executable 2>/dev/null | head -1)
  fi
  if [[ -z "$bin" ]]; then
    echo "ERROR: MiniBrowser binary not found under $BUILD_DIR" >&2
    find "$BUILD_DIR" -maxdepth 3 -type d 2>/dev/null | head -20 >&2
    exit 1
  fi
  cp -aL "$bin" "$DIST/MiniBrowser"

  # Auxiliary processes — WebKit spawns these for network/web/database/etc.
  # Without them MiniBrowser fails at runtime: "Failed to spawn ... WPENetworkProcess".
  # WPE: WPENetworkProcess, WPEWebProcess, WPEDatabaseProcess, ...
  # GTK: WebKitNetworkProcess, WebKitWebProcess, ...
  # Copy every non-MiniBrowser ELF in $BUILD_DIR/bin.
  if [[ -d "$BUILD_DIR/bin" ]]; then
    while IFS= read -r aux; do
      base=$(basename "$aux")
      [[ "$base" == "MiniBrowser" ]] && continue
      cp -aL "$aux" "$DIST/$base"
    done < <(find "$BUILD_DIR/bin" -maxdepth 1 -type f -executable 2>/dev/null)
  fi

  if [[ -d "$BUILD_DIR/lib" ]]; then
    find "$BUILD_DIR/lib" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) \
      -exec cp -aL {} "$DIST/" \;
    find "$BUILD_DIR/lib" -maxdepth 1 -type l -name '*.so*' -exec cp -aL {} "$DIST/" \; 2>/dev/null || true
    # MODULE libraries (injected bundle) may land in nested subdirs mirroring
    # install layout (lib/wpe-webkit-2.0/injected-bundle/, lib/webkitgtk-X/...).
    # Flatten them so the bundle dir is self-contained (WEBKIT_INJECTED_BUNDLE_PATH
    # points at the flat dir).
    find "$BUILD_DIR/lib" -mindepth 2 -type f -name 'lib*njected*ndle*.so*' \
      -exec cp -aL {} "$DIST/" \; 2>/dev/null || true
  fi

  echo "Staged: $(du -sh "$DIST" | cut -f1)"

  bash "$WORK/webkit/scripts/bundle-dist.sh" "$DIST"

  echo "===== Phase 3 complete: $PORT staged + bundled at $DIST ====="
else
  echo "===== Phase 3 already done: $DIST has MiniBrowser ====="
fi

echo "===== apply-and-build-port: PORT=$PORT all phases satisfied ====="
