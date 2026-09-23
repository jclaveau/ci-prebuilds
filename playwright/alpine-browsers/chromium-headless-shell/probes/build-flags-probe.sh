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
#   2. PGO hit rate per directory, with its denominator. Chromium compiles with
#      -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date
#      -Wno-backend-plugin, so a function whose profile no longer matches
#      (aports/copium/PW patches change bodies, musl-conditioned code changes
#      hashes) is silently built un-optimised. Re-enabling the warnings on a
#      sample of TUs counts them. `base/` is the control: it takes few patches,
#      so its mismatch rate is the floor that the profile's own revision drift
#      (linux.pgo.txt names a branch commit, not our exact tag) costs everyone.
#      The warnings alone say how many functions lost their profile, not out
#      of how many had one: the profile's own function list, intersected with
#      each sampled object's defined symbols, is that denominator, and the
#      per-function counts weight both sides. Near 100% of the hot functions
#      mismatching is the compiler (Chromium's profile was collected with its
#      pinned clang snapshot, and the IR-PGO hash follows the pipeline); a few
#      percent is the patches.
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
cd "$WORK/chromium-src/chromium-$CHS_VER" || exit 2
BUILD=out/headless
[[ -f "$BUILD/build.ninja" ]] || { echo "ERROR: $BUILD/build.ninja missing" >&2; exit 2; }

# The compile command ninja would run, cwd = $BUILD. `-t commands` lists the
# whole dependency chain; the target's own compile is the last line.
compile_line() {
  ninja -C "$BUILD" -t commands "$1" 2>/dev/null | tail -1 | sed 's/^sccache //'
}
# Object names are resolved against ninja's own target list rather than
# guessed: gn's obj/ layout nests the target name under the directory.
echo "== chromium $CHS_VER, $BUILD" | tee "$OUT/summary.txt"
cp "$BUILD/args.gn" "$OUT/args.gn"
ninja -C "$BUILD" -t targets all 2>/dev/null | grep -E '\.o:' | cut -d: -f1 | sort > /tmp/all-objs.txt
echo "  $(wc -l < /tmp/all-objs.txt) object targets" | tee -a "$OUT/summary.txt"
if [[ ! -s /tmp/all-objs.txt ]]; then
  echo "ERROR: ninja lists no objects:" | tee -a "$OUT/summary.txt"
  ninja -C "$BUILD" -t targets all 2>&1 >/dev/null | head -5 | tee -a "$OUT/summary.txt"
  exit 2
fi
# gn names an object obj/<BUILD.gn dir>/<target>/<basename>.o, so a source in
# a subdirectory of its target (all of blink core: core/layout/x.cc compiles to
# obj/third_party/blink/renderer/core/core/x.o) is found by walking up from
# its own directory. Test and fuzzer targets are skipped: ninja lists them even
# though the round never built them.
obj_for_src() {
  local base dir hit
  base=$(basename "$1" .cc); dir=$(dirname "$1")
  while :; do
    hit=$(grep -E "^obj/$dir/[^/]+/$base\.o$" /tmp/all-objs.txt | grep -vE '/[^/]*(test|fuzzer)[^/]*/[^/]+$' | head -1)
    [[ -n "$hit" ]] && { echo "$hit"; return; }
    [[ "$dir" == */* ]] || return 1
    dir=${dir%/*}
  done
}
# Non-test sources of a directory, in the order ls gives them.
srcs_in_dir() { printf "%s\n" "$1"/*.cc | grep -vE '(_unittest|_test|_perftest|_fuzzer|test_support|_browsertest)\.cc$'; }

# ---- 1. command lines -------------------------------------------------------
for src in \
  third_party/blink/renderer/core/layout/layout_block_flow.cc \
  third_party/blink/renderer/core/dom/element.cc \
  base/values.cc; do
  obj=$(obj_for_src "$src")
  [[ -n "$obj" ]] || { echo "WARN: no object for $src" | tee -a "$OUT/summary.txt"; continue; }
  name=$(basename "$obj" .o)
  line=$(compile_line "$obj")
  [[ -n "$line" ]] || { echo "WARN: no command for $obj" | tee -a "$OUT/summary.txt"; continue; }
  printf '%s\n' "$line" > "$OUT/cmd-$name.txt"
  # -### prints the driver's resolved cc1 invocation without compiling; kept
  # whole, quoted, so a flag's value ("-stack-protector" "1") stays with it.
  (cd "$BUILD" && eval "$line -###" 2>&1 | grep -E '"-cc1"') > "$OUT/cc1-$name.txt" || true
  echo "  $name ($obj): $(wc -w < "$OUT/cmd-$name.txt") driver args, $(grep -o '"-' "$OUT/cc1-$name.txt" | wc -l) cc1 flags" | tee -a "$OUT/summary.txt"
done

# Flags of interest with their values, so the summary answers without opening
# the files.
echo "== cc1 flags of interest (layout_block_flow)" | tee -a "$OUT/summary.txt"
grep -oE '"-(stack-protector|fstack-clash[^"]*|fno-unwind[^"]*|funwind[^"]*|ffp-contract[^"]*|O[0-3s]|flto[^"]*|fprofile[^"]*|fwhole[^"]*|fsplit[^"]*|mllvm|target-feature|tune-cpu|target-cpu|fno-plt|D_FORTIFY[^"]*|fvisibility[^"]*|mframe[^"]*|fdata-sections|ffunction-sections|fsanitize[^"]*|inlinehint-threshold[^"]*|mrelocation-model|pic-level|pie-level)" ?("[^-][^"]*")?' \
  "$OUT/cc1-layout_block_flow.txt" | tr -d '"' | sort -u | tr '\n' ' ' | tee -a "$OUT/summary.txt" || true
echo | tee -a "$OUT/summary.txt"

# ---- 2. PGO hit rate --------------------------------------------------------
# Re-run a sample of each directory's compiles with the three warnings back on
# (a later -W wins over an earlier -Wno-). Output goes to /tmp so obj/ is not
# touched; the .d file rewrite is harmless in a throwaway container.
PGO_ON="-Wprofile-instr-unprofiled -Wprofile-instr-out-of-date -Wbackend-plugin"
# Recompile every object of /tmp/objs-<list>.txt with the three warnings on,
# one per TU, nproc at a time, outputs under /tmp/pgo-<tag>; the merged log is
# on stdout. A third argument swaps the compiler binary directory (the
# alternate clang of part 4). List and output tags are separate because run
# 34808672663 read the alternate clang's list from a file it never had.
recompile_with_warnings() {
  local list="$1" tag="$2" altbin="$3"
  rm -rf "/tmp/pgo-$tag"; mkdir -p "/tmp/pgo-$tag"
  xargs -P "$(nproc)" -I{} bash -c '
    obj="$1"; tag="$2"; build="$3"; pgo_on="$4"; altbin="$5"
    line=$(ninja -C "$build" -t commands "$obj" 2>/dev/null | tail -1 | sed "s/^sccache //")
    [ -n "$line" ] || exit 0
    # Same command, warnings on, object to a private path so obj/ is not touched.
    line=$(printf "%s" "$line" | sed -E "s# -o [^ ]+# -o /tmp/pgo-$tag/$(echo "$obj" | tr / _)#")
    [ -n "$altbin" ] && line=$(printf "%s" "$line" | sed -E "s#^[^ ]*/(clang\\+\\+|clang) #$altbin/\\1 #")
    { echo "### $obj"; (cd "$build" && eval "$line $pgo_on" 2>&1 || true); } > "/tmp/pgo-$tag/$(echo "$obj" | tr / _).log"
  ' _ {} "$tag" "$BUILD" "$PGO_ON" "$altbin" < "/tmp/objs-$list.txt"
  cat "/tmp/pgo-$tag"/*.log 2>/dev/null || true
}
echo "== PGO warnings, $SAMPLE TUs per dir (out-of-date = hash mismatch, profile dropped; unprofiled = no data; backend = CFG mismatch)" | tee -a "$OUT/summary.txt"
printf '%-45s %5s %12s %11s %8s %14s\n' dir TUs out-of-date unprofiled backend 'fn mismatch/of' | tee -a "$OUT/summary.txt"
for dir in \
  third_party/blink/renderer/core/layout \
  third_party/blink/renderer/core/dom \
  third_party/blink/renderer/core/css \
  third_party/blink/renderer/platform \
  base; do
  tag=$(echo "$dir" | tr / _)
  : > "/tmp/objs-$tag.txt"
  for src in $(srcs_in_dir "$dir" | head -n "$SAMPLE"); do obj_for_src "$src" >> "/tmp/objs-$tag.txt"; done
  n=$(wc -l < "/tmp/objs-$tag.txt")
  recompile_with_warnings "$tag" "$tag" "" > "$OUT/pgo-$tag.log"
  ood=$(grep -c 'profile-instr-out-of-date' "$OUT/pgo-$tag.log" || true)
  unp=$(grep -c 'profile-instr-unprofiled' "$OUT/pgo-$tag.log" || true)
  bck=$(grep -c 'backend-plugin' "$OUT/pgo-$tag.log" || true)
  # The out-of-date warning is per file but carries the function tally.
  fns=$(grep -hoE 'of [0-9]+ functions?, [0-9]+ have mismatched' "$OUT/pgo-$tag.log" | awk '{n+=$2; m+=$4} END{printf "%d/%d", m, n}')
  printf '%-45s %5s %12s %11s %8s %14s\n' "$dir" "$n" "$ood" "$unp" "$bck" "$fns" | tee -a "$OUT/summary.txt"
done

# ---- 3. denominator ---------------------------------------------------------
# Profile entries with their hottest block count: the number the mismatch
# warning reports as "up to N count discarded". An IR-instrumented profile has
# no "Function count" line (run 34791649697), only "Block counts: [...]"; those
# lists are too big for a file, so the listing streams through awk.
PROFDATA=$(grep -oE 'fprofile-use=[^ ]+' "$OUT/cmd-values.txt" | head -1 | cut -d= -f2-)
LLVM_BIN=$(dirname "$(awk '{print $1}' "$OUT/cmd-values.txt")")
(cd "$BUILD" && "$LLVM_BIN/llvm-profdata" show --all-functions --counts "$PROFDATA" 2> "$OUT/profdata.err") \
  | awk '/^  [^ ]/ { name=$1; sub(/:$/, "", name) }
         /^    Block counts:/ { m=0; l=$0; sub(/.*\[/, "", l); sub(/\].*/, "", l); n=split(l, a, /, */); for (i=1; i<=n; i++) if (a[i]+0 > m) m=a[i]+0; print name, m }' \
  | LC_ALL=C sort -u > /tmp/profile-fns.txt
head -3 "$OUT/profdata.err" | tee -a "$OUT/summary.txt"
echo "== profile: $(wc -l < /tmp/profile-fns.txt) functions with block counts" | tee -a "$OUT/summary.txt"
echo "== PGO denominator: functions of the sampled TUs that have a profile entry, vs those whose hash mismatched" | tee -a "$OUT/summary.txt"
printf '%-45s %9s %9s %6s %16s %16s %6s\n' dir profiled mismatch 'fn%' 'counts profiled' 'counts dropped' 'cnt%' | tee -a "$OUT/summary.txt"
for dir in \
  third_party/blink/renderer/core/layout \
  third_party/blink/renderer/core/dom \
  third_party/blink/renderer/core/css \
  third_party/blink/renderer/platform \
  base; do
  tag=$(echo "$dir" | tr / _)
  # Defined functions across the sampled objects (bitcode under ThinLTO, so
  # llvm-nm), joined with the profile's names.
  while read -r obj; do "$LLVM_BIN/llvm-nm" --defined-only "$BUILD/$obj" 2>> "$OUT/nm-$tag.err" | awk '$2 ~ /^[tTwW]$/ { print $3 }'; done \
    < "/tmp/objs-$tag.txt" | LC_ALL=C sort -u > "$OUT/defined-$tag.txt"
  # awk, not join: the round image is Alpine and busybox has no join applet
  # (run 34797323579 joined 801 defined names against 1.18M profile entries
  # into nothing, with the error in a dropped stderr).
  awk 'NR == FNR { c[$1] = $2; next } ($1 in c) { print $1, c[$1] }' /tmp/profile-fns.txt "$OUT/defined-$tag.txt" > "$OUT/profiled-$tag.txt"
  grep -oE '\(hash mismatch\) [^ ]+ Hash = [0-9]+ up to [0-9]+' "$OUT/pgo-$tag.log" \
    | awk '{ print $3, $NF }' | sort -u > "$OUT/mismatched-$tag.txt"
  read -r np cp < <(awk '{ n++; c+=$2 } END { printf "%d %d", n, c }' "$OUT/profiled-$tag.txt")
  read -r nm cm < <(awk '{ n++; c+=$2 } END { printf "%d %d", n, c }' "$OUT/mismatched-$tag.txt")
  printf '%-45s %9s %9s %5.1f%% %16s %16s %5.1f%%\n' "$dir" "$np" "$nm" \
    "$(awk -v a="$nm" -v b="$np" 'BEGIN { print (b ? 100*a/b : 0) }')" "$cp" "$cm" \
    "$(awk -v a="$cm" -v b="$cp" 'BEGIN { print (b ? 100*a/b : 0) }')" | tee -a "$OUT/summary.txt"
done

# Which layout functions lost their profile — the names say whether the misses
# sit on the hot path or in patched corners.
grep -hoiE "function control flow change detected \(hash mismatch\) [^ ]+|no profile data available for function '[^']+'|'[^']+' has a mismatched profile" \
  "$OUT/pgo-third_party_blink_renderer_core_layout.log" | sort | uniq -c | sort -rn | head -40 \
  > "$OUT/layout-mismatched-functions.txt" || true
echo "== $(wc -l < "$OUT/layout-mismatched-functions.txt") distinct layout functions named in warnings (top in layout-mismatched-functions.txt)" | tee -a "$OUT/summary.txt"

# ---- 4. the same sample under another clang --------------------------------
# The profile's hashes come from Chromium's pinned clang snapshot. If the
# snapshot itself (mounted by the workflow as ALT_CLANG) mismatches the same
# functions, the loss is the profile's revision drift and official pays it
# too; if it matches them, the loss is our compiler's and a chain on the
# snapshot recovers it.
if [[ -n "${ALT_CLANG:-}" ]]; then
  echo "== alternate clang: $("$ALT_CLANG/clang++" --version 2>&1 | head -1)" | tee -a "$OUT/summary.txt"
  printf '%-45s %5s %13s %12s %13s %12s\n' dir TUs 'mismatch ours' 'hot ours' 'mismatch alt' 'hot alt' | tee -a "$OUT/summary.txt"
  for dir in \
    third_party/blink/renderer/core/layout \
    third_party/blink/renderer/core/dom \
    base; do
    tag=$(echo "$dir" | tr / _)
    n=$(wc -l < "/tmp/objs-$tag.txt")
    recompile_with_warnings "$tag" "alt-$tag" "$ALT_CLANG" > "$OUT/pgo-alt-$tag.log"
    # An empty log is a probe that did not run, not a compiler that matched.
    [[ -s "$OUT/pgo-alt-$tag.log" ]] || echo "ERROR: alternate recompile of $dir produced no log" | tee -a "$OUT/summary.txt"
    # A different compiler may fail on a TU outright; that shows as errors, not
    # as a clean zero.
    err=$(grep -c ' error: ' "$OUT/pgo-alt-$tag.log" || true)
    grep -oE '\(hash mismatch\) [^ ]+ Hash = [0-9]+ up to [0-9]+' "$OUT/pgo-alt-$tag.log" \
      | awk '{ print $3, $NF }' | sort -u > "$OUT/mismatched-alt-$tag.txt"
    printf '%-45s %5s %13s %12s %13s %12s  (%s errors)\n' "$dir" "$n" \
      "$(wc -l < "$OUT/mismatched-$tag.txt")" "$(awk '$2 > 0' "$OUT/mismatched-$tag.txt" | wc -l)" \
      "$(wc -l < "$OUT/mismatched-alt-$tag.txt")" "$(awk '$2 > 0' "$OUT/mismatched-alt-$tag.txt" | wc -l)" "$err" | tee -a "$OUT/summary.txt"
  done
fi

# ---- 5. the residual mismatches, and whether we could profile ourselves -----
# Part 4 answered "is it our compiler"; CFI turned 330 mismatches into 18 on
# the six hot TUs (run 35036941795). Those 18 sit in exactly the functions the
# nav row runs — Element::AttributeChanged 62 M counts, RecalcOwnStyle 19 M,
# PseudoStateChanged 10 M — so some other flag of the official build still
# shapes their CFG. Google's profile is a BORROWED artifact: every flag that
# changes IR before the hash is computed has to match theirs, and we only ever
# checked the ones we had a reason to suspect.
#
# 5a lists the CFG-shaping flags the build does NOT pass and re-counts the
# residual with each one added, one variant at a time. A variant that drops
# the mismatch count is the missing flag; all of them flat means the borrowed
# profile cannot be made to fit and the answer is 5b.
RESIDUAL_SRCS="
third_party/blink/renderer/core/dom/element.cc
third_party/blink/renderer/core/css/resolver/style_adjuster.cc
third_party/blink/renderer/core/layout/block_node.cc
third_party/blink/renderer/core/layout/block_layout_algorithm.cc
"
: > /tmp/objs-residual.txt
for src in $RESIDUAL_SRCS; do obj_for_src "$src" >> /tmp/objs-residual.txt; done
echo "== residual TUs: $(wc -l < /tmp/objs-residual.txt) of 4 resolved" | tee -a "$OUT/summary.txt"

# Presence is read off the resolved cc1 line, not the driver args: Chromium
# passes some of these through -Xclang and the driver adds others itself.
echo "== CFG-shaping flags on the element.cc cc1 line" | tee -a "$OUT/summary.txt"
CC1_ELEMENT="$OUT/cc1-element.txt"
VARIANTS=""
for flag in -fwhole-program-vtables -fsplit-lto-unit -fno-semantic-interposition \
            -fsanitize=cfi-mfcall -fforce-emit-vtables; do
  if [[ -s "$CC1_ELEMENT" ]] && grep -qF -- "$flag" "$CC1_ELEMENT"; then
    echo "  present: $flag" | tee -a "$OUT/summary.txt"
  else
    echo "  ABSENT : $flag" | tee -a "$OUT/summary.txt"
    VARIANTS="$VARIANTS $flag"
  fi
done

# One variant per pass, baseline first, so a drop is attributable to a single
# flag. -Wno- is overridden by the later -W, same trick as part 2.
printf '%-34s %9s %16s\n' variant 'fns mismatch' 'counts dropped' | tee -a "$OUT/summary.txt"
for variant in BASELINE $VARIANTS; do
  extra=""; [[ "$variant" == BASELINE ]] || extra="$variant"
  vtag=$(echo "$variant" | tr -c 'A-Za-z0-9' '_')
  rm -rf "/tmp/pgo-var-$vtag"; mkdir -p "/tmp/pgo-var-$vtag"
  xargs -P "$(nproc)" -I{} bash -c '
    obj="$1"; vtag="$2"; build="$3"; pgo_on="$4"; extra="$5"
    line=$(ninja -C "$build" -t commands "$obj" 2>/dev/null | tail -1 | sed "s/^sccache //")
    [ -n "$line" ] || exit 0
    line=$(printf "%s" "$line" | sed -E "s# -o [^ ]+# -o /tmp/pgo-var-$vtag/$(echo "$obj" | tr / _)#")
    { echo "### $obj"; (cd "$build" && eval "$line $pgo_on $extra" 2>&1 || true); } \
      > "/tmp/pgo-var-$vtag/$(echo "$obj" | tr / _).log"
  ' _ {} "$vtag" "$BUILD" "$PGO_ON" "$extra" < /tmp/objs-residual.txt
  cat "/tmp/pgo-var-$vtag"/*.log 2>/dev/null > "$OUT/pgo-var-$vtag.log"
  # A variant clang rejects outright would read as a clean zero otherwise.
  verr=$(grep -c ' error: ' "$OUT/pgo-var-$vtag.log" || true)
  grep -oE '\(hash mismatch\) [^ ]+ Hash = [0-9]+ up to [0-9]+' "$OUT/pgo-var-$vtag.log" \
    | awk '{ print $3, $NF }' | sort -u > "$OUT/mismatched-var-$vtag.txt"
  read -r nv cv < <(awk '{ n++; c+=$2 } END { printf "%d %d", n, c }' "$OUT/mismatched-var-$vtag.txt")
  printf '%-34s %9s %16s  (%s errors)\n' "$variant" "$nv" "$cv" "$verr" | tee -a "$OUT/summary.txt"
done

# 5b. Could we generate our own profile instead of borrowing Google's?
# The prerequisite is the one that killed three firefox dispatches: a clang
# whose -fprofile-generate runtime (libclang_rt.profile) actually exists for
# the target. Alpine's clang ships as a bare compiler when aports' pin and
# edge's default llvm disagree, and the miss only surfaces at LINK time, so a
# compile-only check would pass and the 30 h build would still die.
echo "== self-PGO prerequisite: -fprofile-generate roundtrip" | tee -a "$OUT/summary.txt"
CLANGXX=$(awk '{print $1}' "$OUT/cmd-values.txt")
echo "  clang: $("$CLANGXX" --version 2>&1 | head -1)" | tee -a "$OUT/summary.txt"
echo "  resource dir: $("$CLANGXX" -print-resource-dir 2>&1)" | tee -a "$OUT/summary.txt"
ls "$("$CLANGXX" -print-resource-dir 2>/dev/null)/lib"/*/libclang_rt.profile* 2>/dev/null \
  | tee -a "$OUT/summary.txt" || echo "  no libclang_rt.profile* under the resource dir" | tee -a "$OUT/summary.txt"
cat > /tmp/pgen.cc <<'CCEOF'
#include <cstdio>
int spin(int n) { int a = 0; for (int i = 0; i < n; i++) a += i % 7; return a; }
int main() { std::printf("%d\n", spin(1000)); return 0; }
CCEOF
if "$CLANGXX" -fprofile-generate -o /tmp/pgen /tmp/pgen.cc 2> "$OUT/pgen-link.err"; then
  ( cd /tmp && LLVM_PROFILE_FILE=/tmp/pgen.profraw /tmp/pgen >/dev/null 2>&1 )
  if [[ -s /tmp/pgen.profraw ]] \
     && "$LLVM_BIN/llvm-profdata" merge -o /tmp/pgen.profdata /tmp/pgen.profraw 2>> "$OUT/pgen-link.err"; then
    echo "  OK: link + run + llvm-profdata merge ($(stat -c%s /tmp/pgen.profdata) bytes)" | tee -a "$OUT/summary.txt"
  else
    echo "  FAIL: linked, but no usable profraw — see pgen-link.err" | tee -a "$OUT/summary.txt"
  fi
else
  echo "  FAIL: -fprofile-generate does not link:" | tee -a "$OUT/summary.txt"
  head -5 "$OUT/pgen-link.err" | tee -a "$OUT/summary.txt"
fi
