#!/usr/bin/env bash
# Idempotent + progressive per-port WebKit build.
#
# Reads PORT env (WPE or GTK). Runs phases gated on sentinel files in the
# inherited image filesystem:
#
#   0. PGO profile       — WK_PGO=on, PORT=WPE only: instrumented build +
#                          corpus run + merge, until $WORK/pgo/merged.profdata
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
#   WK_PGO                on or off (default off) — see Phase 0
#   PGO_CORPUS_SECONDS    seconds the corpus drives MiniBrowser (default 1800)

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
: "${WK_PGO:=off}"
: "${PGO_CORPUS_SECONDS:=1800}"
: "${PGO_HTTP_PORT:=18080}"
PGO_DIR="$WORK/pgo"
PGO_RAW="$PGO_DIR/raw"
PGO_PROFILE="$PGO_DIR/merged.profdata"
GEN_BUILD_DIR="$SRC/WebKitBuild/$PORT/Release-pgo-gen"
echo "Flags: ENABLE_JIT=$ENABLE_JIT STAGE_NINJA_TIMEOUT=${STAGE_NINJA_TIMEOUT}s WK_PGO=$WK_PGO"

# Injected bundle target names, used by Phase 0's instrumented build and by
# Phase 2.5. WPEWebProcess loads it at runtime, so the profile run needs it.
case "$PORT" in
  WPE)  BUNDLE_TARGETS="WPEInjectedBundle" ;;
  GTK)  BUNDLE_TARGETS="webkitgtkinjectedbundle webkit2gtkinjectedbundle" ;;
  *)    BUNDLE_TARGETS="" ;;
esac

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

# The overlay pins -DCMAKE_C_FLAGS outright, so env CFLAGS never reaches the
# build and PGO flags have to be appended to the overlay's own value.
overlay_flag_value() {
  local entry
  for entry in "${CMAKE_SHARED_FLAGS[@]}"; do
    if [[ "$entry" == "-D$1="* ]]; then echo "${entry#-D$1=}"; return; fi
  done
}

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

# Phase 0 — PGO profile (WK_PGO=on, WPE only).
#
# Two passes inside this same checkpoint lineage rather than a second image
# lineage with artifact passing (firefox's shape): an instrumented build in
# $GEN_BUILD_DIR, a MiniBrowser run over WebKit's own PerformanceTests, a merge
# into $PGO_PROFILE, and then the ordinary Release build below compiles with
# -fprofile-use. Gated on $PGO_PROFILE like every other phase is gated on its
# sentinel, so a resume stage that inherits a finished merge goes straight to
# Phase 1.
#
# The corpus is upstream's PerformanceTests, NOT the kernels perf-gate-webkit
# grades. Training on the graded workload was measured to be a wash on firefox
# (see project_ff_pgo_corpus_append_experiment), and holding the graded kernels
# out of the corpus is what keeps the gate number honest.
#
# WPE only: `--headless` is a WPE MiniBrowser flag, and the GTK chain is not
# graded by perf-gate-webkit, so instrumenting it would only cost wall time.
if [[ "$WK_PGO" == "on" && "$PORT" == "WPE" && ! -s "$PGO_PROFILE" ]]; then
  echo "===== Phase 0: PGO instrumented build + profile run ====="

  # Alpine's llvm package installs to /usr/lib/llvm<N>/bin without symlinking
  # onto PATH, and llvm-profdata refuses a profile written by a NEWER runtime,
  # so prefer the llvm matching the clang that will write the profiles.
  CLANG_MAJOR=$("$CC" --version | sed -n 's/.*version \([0-9]\+\).*/\1/p' | head -n 1)
  LLVM_PROFDATA=$(command -v llvm-profdata || true)
  if [[ -x "/usr/lib/llvm${CLANG_MAJOR}/bin/llvm-profdata" ]]; then
    LLVM_PROFDATA="/usr/lib/llvm${CLANG_MAJOR}/bin/llvm-profdata"
  fi
  if [[ -z "$LLVM_PROFDATA" ]]; then
    echo "ERROR: no llvm-profdata for clang $CLANG_MAJOR (looked on PATH and in /usr/lib/llvm*/bin)" >&2
    exit 1
  fi
  echo "  clang major $CLANG_MAJOR, llvm-profdata $LLVM_PROFDATA"

  # A missing libclang_rt.profile links fine and then writes nothing at runtime,
  # which would only surface after the instrumented build has burnt its hours.
  # The probe compiles a real main: an empty translation unit fails the link on
  # `undefined reference to main` whether or not the profile runtime is there,
  # so it would report a missing runtime on every toolchain. clang's stderr is
  # kept because "cannot find libclang_rt.profile.a" is the line that tells the
  # two apart.
  printf 'int main(void){return 0;}\n' > /tmp/pgo-link-probe.c
  if ! "$CC" -fprofile-generate /tmp/pgo-link-probe.c -o /tmp/pgo-link-probe; then
    echo "ERROR: $CC cannot link -fprofile-generate — compiler-rt's profile runtime is missing" >&2
    exit 1
  fi
  rm -f /tmp/pgo-link-probe /tmp/pgo-link-probe.c

  mkdir -p "$PGO_RAW"

  # -fprofile-continuous because the corpus run is ended by SIGTERM: an
  # instrumented binary writes its counters from atexit, so a killed
  # MiniBrowser would leave an empty profile.
  PGO_GEN_FLAGS="-fprofile-generate=$PGO_RAW -fprofile-continuous"

  if [[ ! -f "$GEN_BUILD_DIR/CMakeCache.txt" ]]; then
    echo "--- Phase 0: cmake configure (instrumented) ---"
    mkdir -p "$GEN_BUILD_DIR"
    # LTO_MODE empty disables LTO for this pass (WebKitCompilerFlags.cmake gates
    # on the variable being truthy). The profile is IR-level and LTO-independent,
    # and thin-LTO linking every instrumented library would not fit the stage.
    cmake -GNinja \
      -DPORT="$PORT" \
      -S "$SRC" \
      -B "$GEN_BUILD_DIR" \
      "${CMAKE_SHARED_FLAGS[@]}" \
      -DLTO_MODE= \
      "-DCMAKE_C_FLAGS=$(overlay_flag_value CMAKE_C_FLAGS) $PGO_GEN_FLAGS" \
      "-DCMAKE_CXX_FLAGS=$(overlay_flag_value CMAKE_CXX_FLAGS) $PGO_GEN_FLAGS" \
      "-DCMAKE_EXE_LINKER_FLAGS=$LDFLAGS $PGO_GEN_FLAGS" \
      "-DCMAKE_SHARED_LINKER_FLAGS=$LDFLAGS $PGO_GEN_FLAGS" \
      "-DCMAKE_MODULE_LINKER_FLAGS=$LDFLAGS $PGO_GEN_FLAGS"
  else
    echo "--- Phase 0: instrumented tree already configured ---"
  fi

  if [[ ! -f "$GEN_BUILD_DIR/bin/MiniBrowser" ]]; then
    for hdr_target in WTF_CopyHeaders bmalloc_CopyHeaders JavaScriptCore_CopyPrivateHeaders; do
      cmake --build "$GEN_BUILD_DIR" --target "$hdr_target" || \
        echo "note: $hdr_target not present in this WebKit revision — skipping"
    done

    # Reserve the corpus run's budget plus slack: a Phase 0 that ninja'd right
    # up to the stage deadline would resume with nothing to show for the hours.
    GEN_NINJA_SECONDS=$(( $(remaining_seconds) - PGO_CORPUS_SECONDS - 900 ))
    if (( GEN_NINJA_SECONDS < 600 )); then
      echo "===== Phase 0 incomplete (no room left this stage); next resume continues ====="
      mkdir -p "$DIST"
      exit 0
    fi
    echo "--- Phase 0: ninja instrumented MiniBrowser (timeout: ${GEN_NINJA_SECONDS}s) ---"
    rc=0
    timeout -s TERM "$GEN_NINJA_SECONDS" \
      cmake --build "$GEN_BUILD_DIR" --target MiniBrowser || rc=$?
    echo "Phase 0: instrumented ninja exit rc=$rc"
    sccache --show-stats || true
    if [[ ! -f "$GEN_BUILD_DIR/bin/MiniBrowser" ]]; then
      if [[ "$rc" != 143 ]] && [[ "$rc" != 124 ]]; then
        echo "ERROR: instrumented ninja failed with rc=$rc (not a timeout)" >&2
        exit 1
      fi
      echo "===== Phase 0 incomplete (timed out); next resume continues ====="
      mkdir -p "$DIST"
      exit 0
    fi
  else
    echo "--- Phase 0: instrumented MiniBrowser already built ---"
  fi

  for tgt in $BUNDLE_TARGETS; do
    cmake --build "$GEN_BUILD_DIR" --target "$tgt" || \
      echo "ninja target $tgt: skipped (not present in this WebKit revision)"
  done

  # The build tree sets CMAKE_SKIP_RPATH, so the run needs the same environment
  # pw_run.sh exports when it runs MiniBrowser out of a build folder.
  export LD_LIBRARY_PATH="$GEN_BUILD_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export WEBKIT_EXEC_PATH="$GEN_BUILD_DIR/bin"
  export WEBKIT_INJECTED_BUNDLE_PATH="$GEN_BUILD_DIR/lib"
  export WEBKIT_FORCE_COMPLEX_TEXT=1
  export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
  export HOME="${HOME:-/root}"
  export XDG_RUNTIME_DIR=/tmp/pgo-xdg
  mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
  export LLVM_PROFILE_FILE="$PGO_RAW/wk-%p-%c.profraw"

  # Smoke the instrumented binary before the corpus: "MiniBrowser cannot run
  # headless in this builder" and "the corpus never started" produce the same
  # empty profile, and only one of them is worth a retry.
  echo "--- Phase 0: instrumented smoke run ---"
  timeout -s TERM 120 "$GEN_BUILD_DIR/bin/MiniBrowser" --headless about:blank || true
  SMOKE_RAW=$(find "$PGO_RAW" -name '*.profraw' | wc -l)
  echo "  smoke profraw files: $SMOKE_RAW"
  if (( SMOKE_RAW == 0 )); then
    echo "ERROR: the instrumented MiniBrowser wrote no profile on about:blank —" >&2
    echo "       it could not run here, so the corpus run would measure nothing." >&2
    exit 1
  fi

  # Continuous mode creates the .profraw at startup, so file count alone cannot
  # tell a corpus that ran from one that failed to load. about:blank is the
  # control: the corpus has to move the counts well past browser startup.
  profile_total_count() {
    "$LLVM_PROFDATA" show "$1" | awk -F': ' '/^Total count/ {print $2; exit}'
  }
  "$LLVM_PROFDATA" merge -output="$PGO_DIR/smoke.profdata" "$PGO_RAW"/*.profraw
  SMOKE_COUNT=$(profile_total_count "$PGO_DIR/smoke.profdata")
  echo "  about:blank total count: ${SMOKE_COUNT:-unreported}"
  rm -f "$PGO_RAW"/*.profraw "$PGO_DIR/smoke.profdata"

  # Same-origin http, because the driver page calls the benchmark's startTest()
  # across the iframe boundary and file:// gives every document its own origin.
  echo "--- Phase 0: corpus run (${PGO_CORPUS_SECONDS}s) ---"
  cp "$WORK/webkit/pgo-corpus/train.html" "$SRC/PerformanceTests/train.html"
  bash "$WORK/webkit/pgo-corpus/build-manifest.sh" \
    "$SRC/PerformanceTests" "$SRC/PerformanceTests/corpus-manifest.json" \
    "$PGO_CORPUS_SECONDS"
  python3 -m http.server --bind 127.0.0.1 --directory "$SRC/PerformanceTests" \
    "$PGO_HTTP_PORT" >/dev/null 2>&1 &
  HTTPD_PID=$!
  timeout -s TERM "$PGO_CORPUS_SECONDS" \
    "$GEN_BUILD_DIR/bin/MiniBrowser" --headless \
    "http://127.0.0.1:$PGO_HTTP_PORT/train.html" || true
  kill "$HTTPD_PID" 2>/dev/null || true

  RAW_COUNT=$(find "$PGO_RAW" -name '*.profraw' | wc -l)
  echo "  profraw files after corpus: $RAW_COUNT"
  if (( RAW_COUNT < 2 )); then
    echo "ERROR: expected at least a UI process and a WPEWebProcess profile, got $RAW_COUNT" >&2
    exit 1
  fi

  "$LLVM_PROFDATA" merge -output="$PGO_PROFILE" "$PGO_RAW"/*.profraw
  "$LLVM_PROFDATA" show "$PGO_PROFILE" | head -n 12
  MAX_BLOCK=$("$LLVM_PROFDATA" show "$PGO_PROFILE" \
    | awk -F': ' '/Maximum internal block count/ {print $2; exit}')
  if [[ ! "$MAX_BLOCK" =~ ^[0-9]+$ ]] || (( MAX_BLOCK == 0 )); then
    echo "ERROR: merged profile has a zero maximum block count — the corpus ran no code" >&2
    exit 1
  fi
  CORPUS_COUNT=$(profile_total_count "$PGO_PROFILE")
  echo "  corpus total count: ${CORPUS_COUNT:-unreported} (about:blank: ${SMOKE_COUNT:-unreported})"
  if [[ "$SMOKE_COUNT" =~ ^[0-9]+$ && "$CORPUS_COUNT" =~ ^[0-9]+$ ]]; then
    if (( CORPUS_COUNT < SMOKE_COUNT * 3 )); then
      echo "ERROR: the corpus contributed less than 3x browser startup — no entry" >&2
      echo "       ran, so this profile would train on startup only." >&2
      exit 1
    fi
  else
    echo "  note: no plain-integer Total count from this llvm-profdata; ratio check skipped"
  fi

  # Dropped in the same layer it was created in, so a Phase 0 that completes in
  # one stage never ships the instrumented tree to the stages that follow.
  rm -rf "$GEN_BUILD_DIR" "$PGO_RAW"
  echo "===== Phase 0 complete: $PGO_PROFILE ====="
elif [[ "$WK_PGO" == "on" && "$PORT" == "WPE" ]]; then
  echo "===== Phase 0 already done: $PGO_PROFILE exists ====="
fi

# -fprofile-use for the Release build below. Appended, so cmake's last
# -DCMAKE_C_FLAGS wins over the overlay's.
if [[ "$WK_PGO" == "on" && -s "$PGO_PROFILE" ]]; then
  PGO_USE_FLAGS="-fprofile-use=$PGO_PROFILE -Wno-backend-plugin"
  CMAKE_SHARED_FLAGS+=(
    "-DCMAKE_C_FLAGS=$(overlay_flag_value CMAKE_C_FLAGS) $PGO_USE_FLAGS"
    "-DCMAKE_CXX_FLAGS=$(overlay_flag_value CMAKE_CXX_FLAGS) $PGO_USE_FLAGS"
  )
  echo "PGO: Release pass compiles with $PGO_USE_FLAGS"
fi

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
# explicitly; target names come from the case above. Idempotent via marker file.
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
