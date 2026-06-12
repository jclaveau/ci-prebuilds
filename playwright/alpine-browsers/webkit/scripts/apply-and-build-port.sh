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
    echo "===== Phase 2 incomplete; next resume continues PORT=$PORT ====="
    mkdir -p "$DIST"
    exit 0
  fi
  echo "===== Phase 2 complete: $PORT MiniBrowser built ====="
else
  echo "===== Phase 2 already done: $BUILD_DIR/bin/MiniBrowser exists ====="
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

  if [[ -d "$BUILD_DIR/lib" ]]; then
    find "$BUILD_DIR/lib" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) \
      -exec cp -aL {} "$DIST/" \;
    find "$BUILD_DIR/lib" -maxdepth 1 -type l -name '*.so*' -exec cp -aL {} "$DIST/" \; 2>/dev/null || true
  fi

  echo "Staged: $(du -sh "$DIST" | cut -f1)"

  bash "$WORK/webkit/scripts/bundle-dist.sh" "$DIST"

  echo "===== Phase 3 complete: $PORT staged + bundled at $DIST ====="
else
  echo "===== Phase 3 already done: $DIST has MiniBrowser ====="
fi

echo "===== apply-and-build-port: PORT=$PORT all phases satisfied ====="
