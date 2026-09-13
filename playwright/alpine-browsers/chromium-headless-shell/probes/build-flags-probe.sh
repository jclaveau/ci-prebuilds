#!/usr/bin/env bash
# What the compiler was actually told, and how much of the PGO profile it
# could use — read off a finished round image, no rebuild.
#
# Runs INSIDE the last round image of a green chain (chs-build-rN-sha-<sha>):
# that image carries the source tree, out/headless with its build.ninja, the
# toolchain and the PGO profile, so every compile command is reproducible.
#
# Two questions, one artifact:
#
#   1. The exact cc1 line for a Blink layout object. The binaries have been
#      inspected section by section; the command lines never were, and Alpine's
#      clang driver adds flags Chromium never asked for (its config file, its
#      compiled-in stack-protector default). `-###` shows what reaches cc1
#      after the driver, which is the only line that matters.
#
#   2. PGO hit rate per directory. Chromium compiles with
#      -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date
#      -Wno-backend-plugin, so a function whose profile no longer matches
#      (aports/copium/PW patches change bodies, musl-conditioned code changes
#      hashes) is silently built un-optimised. Re-enabling the warnings on a
#      sample of TUs counts them. `base/` is the control: it takes few patches,
#      so its mismatch rate is the floor that the profile's own revision drift
#      (linux.pgo.txt names a branch commit, not our exact tag) costs everyone.
#
# usage: build-flags-probe.sh <outdir> [sample-per-dir]
# No -e: a missing target or a failed recompile is a finding to print, not a
# reason to stop before the summary exists.
set -uo pipefail

OUT="${1:?outdir}"
SAMPLE="${2:-24}"
mkdir -p "$OUT"

WORK=/work
set -a; . "$WORK/versions.env"; . "$WORK/derived.env"; set +a
CHS_VER="${CHROMIUM_HEADLESS_SHELL_VERSION:?derived.env missing CHROMIUM_HEADLESS_SHELL_VERSION}"
cd "$WORK/chromium-src/chromium-$CHS_VER"
BUILD=out/headless
[[ -f "$BUILD/build.ninja" ]] || { echo "ERROR: $BUILD/build.ninja missing" >&2; exit 2; }

# The compile command ninja would run, cwd = $BUILD. `-t commands` lists the
# whole dependency chain; the target's own compile is the last line.
compile_line() {
  ninja -C "$BUILD" -t commands "$1" 2>/dev/null | tail -1 | sed 's/^sccache //'
}
# Object names are resolved against ninja's own target list rather than
# guessed: gn's obj/ layout nests the target name under the directory.
ninja -C "$BUILD" -t targets all 2>/dev/null | grep -E '\.o:' | cut -d: -f1 | sort > /tmp/all-objs.txt
echo "  $(wc -l < /tmp/all-objs.txt) object targets" | tee -a "$OUT/summary.txt"
if [[ ! -s /tmp/all-objs.txt ]]; then
  echo "ERROR: ninja lists no objects:" | tee -a "$OUT/summary.txt"
  ninja -C "$BUILD" -t targets all 2>&1 >/dev/null | head -5 | tee -a "$OUT/summary.txt"
  exit 2
fi
find_obj() { grep -E "$1" /tmp/all-objs.txt | head -1; }

echo "== chromium $CHS_VER, $BUILD" | tee "$OUT/summary.txt"
cp "$BUILD/args.gn" "$OUT/args.gn"

# ---- 1. command lines -------------------------------------------------------
for pat in \
  '^obj/third_party/blink/renderer/core/layout/.*/layout_block_flow\.o$' \
  '^obj/third_party/blink/renderer/core/dom/.*/element\.o$' \
  '^obj/base/.*/values\.o$'; do
  obj=$(find_obj "$pat")
  [[ -n "$obj" ]] || { echo "WARN: no object matches $pat" | tee -a "$OUT/summary.txt"; continue; }
  name=$(basename "$obj" .o)
  line=$(compile_line "$obj")
  [[ -n "$line" ]] || { echo "WARN: no command for $obj" | tee -a "$OUT/summary.txt"; continue; }
  printf '%s\n' "$line" > "$OUT/cmd-$name.txt"
  # -### prints the driver's resolved cc1 invocation without compiling.
  (cd "$BUILD" && eval "$line -###" 2>&1 | grep -E '"-cc1"' | tr ' ' '\n' | tr -d '"' \
    | grep -E '^-' | sort -u) > "$OUT/cc1-$name.txt" || true
  echo "  $name: $(wc -w < "$OUT/cmd-$name.txt") driver args, $(wc -l < "$OUT/cc1-$name.txt") distinct cc1 flags" | tee -a "$OUT/summary.txt"
done

# Flags of interest, so the summary answers without opening the files.
echo "== cc1 flags of interest (layout_block_flow)" | tee -a "$OUT/summary.txt"
grep -E '^-(stack-protector|fstack-clash|fno-unwind|funwind|ffp-contract|O[0-3s]|flto|fprofile|fwhole|fsplit|mllvm|target-feature|tune-cpu|target-cpu|fno-plt|D_FORTIFY|fvisibility|mframe|fdata-sections|ffunction-sections)' \
  "$OUT/cc1-layout_block_flow.txt" | tee -a "$OUT/summary.txt" || true

# ---- 2. PGO hit rate --------------------------------------------------------
# Re-run a sample of each directory's compiles with the three warnings back on
# (a later -W wins over an earlier -Wno-). Output goes to /tmp so obj/ is not
# touched; the .d file rewrite is harmless in a throwaway container.
PGO_ON="-Wprofile-instr-unprofiled -Wprofile-instr-out-of-date -Wbackend-plugin"
echo "== PGO warnings, $SAMPLE TUs per dir (out-of-date = hash mismatch, profile dropped; unprofiled = no data; backend = CFG mismatch)" | tee -a "$OUT/summary.txt"
printf '%-45s %5s %12s %11s %8s\n' dir TUs out-of-date unprofiled backend | tee -a "$OUT/summary.txt"
for dir in \
  third_party/blink/renderer/core/layout \
  third_party/blink/renderer/core/dom \
  third_party/blink/renderer/core/css \
  third_party/blink/renderer/platform \
  base; do
  tag=$(echo "$dir" | tr / _)
  grep -E "^obj/$dir/" /tmp/all-objs.txt | head -n "$SAMPLE" > "/tmp/objs-$tag.txt"
  # One compile per TU, nproc at a time; each writes its own log, merged after.
  rm -rf "/tmp/pgo-$tag"; mkdir -p "/tmp/pgo-$tag"
  n=$(wc -l < "/tmp/objs-$tag.txt")
  xargs -P "$(nproc)" -I{} bash -c '
    obj="$1"; tag="$2"; build="$3"; pgo_on="$4"
    line=$(ninja -C "$build" -t commands "$obj" 2>/dev/null | tail -1 | sed "s/^sccache //")
    [ -n "$line" ] || exit 0
    # Same command, warnings on, object to a private path so obj/ is not touched.
    line=$(printf "%s" "$line" | sed -E "s# -o [^ ]+# -o /tmp/pgo-$tag/$(echo "$obj" | tr / _)#")
    { echo "### $obj"; (cd "$build" && eval "$line $pgo_on" 2>&1 || true); } > "/tmp/pgo-$tag/$(echo "$obj" | tr / _).log"
  ' _ {} "$tag" "$BUILD" "$PGO_ON" < "/tmp/objs-$tag.txt"
  cat "/tmp/pgo-$tag"/*.log > "$OUT/pgo-$tag.log" 2>/dev/null || : > "$OUT/pgo-$tag.log"
  ood=$(grep -c 'profile-instr-out-of-date' "$OUT/pgo-$tag.log" || true)
  unp=$(grep -c 'profile-instr-unprofiled' "$OUT/pgo-$tag.log" || true)
  bck=$(grep -c 'backend-plugin' "$OUT/pgo-$tag.log" || true)
  printf '%-45s %5s %12s %11s %8s\n' "$dir" "$n" "$ood" "$unp" "$bck" | tee -a "$OUT/summary.txt"
done

# Which layout functions lost their profile — the names say whether the misses
# sit on the hot path or in patched corners.
grep -hoE "Function control flow change detected \(hash mismatch\) [^ ]+|no profile data available for function '[^']+'|'[^']+' has a mismatched profile" \
  "$OUT/pgo-third_party_blink_renderer_core_layout.log" | sort | uniq -c | sort -rn | head -40 \
  > "$OUT/layout-mismatched-functions.txt" || true
echo "== $(wc -l < "$OUT/layout-mismatched-functions.txt") distinct layout functions named in warnings (top in layout-mismatched-functions.txt)" | tee -a "$OUT/summary.txt"
