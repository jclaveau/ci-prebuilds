#!/bin/bash
# DIAG BRANCH ONLY — with CFI on, 18 hot functions in element.cc /
# style_adjuster.cc / block_node.cc / block_layout_algorithm.cc still miss
# the PGO hash (run 35036941795). Which other official-only flag shapes
# their CFG? Recompiles the same six TUs with CFI plus one more flag each and
# counts the hash-mismatch warnings per variant; the cfi variant is the control.
set -uo pipefail
OUT="${1:?outdir}"
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

PGO_ON="-Wprofile-instr-unprofiled -Wprofile-instr-out-of-date -Wbackend-plugin"
TUS="third_party/blink/renderer/core/layout/block_node.cc
third_party/blink/renderer/core/layout/layout_box.cc
third_party/blink/renderer/core/layout/block_layout_algorithm.cc
third_party/blink/renderer/core/layout/layout_block_flow.cc
third_party/blink/renderer/core/css/resolver/style_adjuster.cc
third_party/blink/renderer/core/dom/element.cc"
declare -A VARIANT=(
  [cfi]="-fsanitize=cfi-vcall -fsanitize=cfi-icall -fsanitize-trap=cfi -fsanitize-ignorelist=../../tools/cfi/ignores.txt"
  [cast]="-fsanitize=cfi-vcall -fsanitize=cfi-icall -fsanitize-trap=cfi -fsanitize-ignorelist=../../tools/cfi/ignores.txt -fsanitize=cfi-derived-cast -fsanitize=cfi-unrelated-cast"
  [nvcall]="-fsanitize=cfi-vcall -fsanitize=cfi-icall -fsanitize-trap=cfi -fsanitize-ignorelist=../../tools/cfi/ignores.txt -fsanitize=cfi-nvcall"
  [nojt]="-fsanitize=cfi-vcall -fsanitize=cfi-icall -fsanitize-trap=cfi -fsanitize-ignorelist=../../tools/cfi/ignores.txt -fno-sanitize-cfi-canonical-jump-tables"
  [hardfast]="-fsanitize=cfi-vcall -fsanitize=cfi-icall -fsanitize-trap=cfi -fsanitize-ignorelist=../../tools/cfi/ignores.txt -Wno-macro-redefined -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST"
  [harddebug]="-fsanitize=cfi-vcall -fsanitize=cfi-icall -fsanitize-trap=cfi -fsanitize-ignorelist=../../tools/cfi/ignores.txt -Wno-macro-redefined -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG"
  [noinline]="-fsanitize=cfi-vcall -fsanitize=cfi-icall -fsanitize-trap=cfi -fsanitize-ignorelist=../../tools/cfi/ignores.txt -fno-inline-functions"
)
: > /tmp/objs.txt
for src in $TUS; do
  obj=$(obj_for_src "$src") || { echo "WARN: no object for $src" | tee -a "$OUT/summary.txt"; continue; }
  echo "$obj" >> /tmp/objs.txt
done
echo "== TUs: $(tr '\n' ' ' < /tmp/objs.txt)" | tee -a "$OUT/summary.txt"

run_variant() {  # run_variant <tag> <extra flags>
  local tag="$1" extra="$2"
  rm -rf "/tmp/v-$tag"; mkdir -p "/tmp/v-$tag"
  xargs -P "$(nproc)" -I{} bash -c '
    obj="$1"; tag="$2"; build="$3"; extra="$4"
    line=$(ninja -C "$build" -t commands "$obj" 2>/dev/null | tail -1 | sed "s/^sccache //")
    [ -n "$line" ] || exit 0
    line=$(printf "%s" "$line" | sed -E "s# -o [^ ]+# -o /tmp/v-$tag/$(echo "$obj" | tr / _)#")
    { echo "### $obj"; (cd "$build" && eval "$line $extra" 2>&1 || true); } > "/tmp/v-$tag/$(echo "$obj" | tr / _).log"
  ' _ {} "$tag" "$BUILD" "$PGO_ON $extra" < /tmp/objs.txt
  cat /tmp/v-$tag/*.log > "$OUT/pgo-$tag.log"
  grep -o 'hash mismatch) [^ ]* Hash = [0-9]* up to [0-9]*' "$OUT/pgo-$tag.log" | awk '{print $3, $NF}' | sort > "$OUT/mismatch-$tag.txt"
}
echo "== hash mismatches per variant (functions / counts dropped) across $(wc -l < /tmp/objs.txt) TUs" | tee -a "$OUT/summary.txt"
printf '%-12s %6s %10s %10s %8s  %s\n' variant errors mismatch 'counts' unprof 'extra flags' | tee -a "$OUT/summary.txt"
for tag in cfi cast nvcall nojt hardfast harddebug noinline; do
  run_variant "$tag" "${VARIANT[$tag]}"
  err=$(grep -c ' error: ' "$OUT/pgo-$tag.log" || true)
  n=$(wc -l < "$OUT/mismatch-$tag.txt")
  cnt=$(awk '{s+=$2} END{print s+0}' "$OUT/mismatch-$tag.txt")
  unp=$(grep -c 'profile-instr-unprofiled' "$OUT/pgo-$tag.log" || true)
  printf '%-12s %6s %10s %10s %8s  %s\n' "$tag" "$err" "$n" "$cnt" "$unp" "${VARIANT[$tag]}" | tee -a "$OUT/summary.txt"
done
echo "== cfi mismatches fixed by each variant" | tee -a "$OUT/summary.txt"
for tag in cast nvcall nojt hardfast harddebug noinline; do
  fixed=$(comm -23 <(cut -d' ' -f1 "$OUT/mismatch-cfi.txt") <(cut -d' ' -f1 "$OUT/mismatch-$tag.txt") | wc -l)
  added=$(comm -13 <(cut -d' ' -f1 "$OUT/mismatch-cfi.txt") <(cut -d' ' -f1 "$OUT/mismatch-$tag.txt") | wc -l)
  echo "  $tag: fixed $fixed, newly mismatched $added" | tee -a "$OUT/summary.txt"
  comm -23 <(cut -d' ' -f1 "$OUT/mismatch-cfi.txt") <(cut -d' ' -f1 "$OUT/mismatch-$tag.txt") | sed "s/^/    fixed  /" | tee -a "$OUT/summary.txt"
done
echo "== first errors per variant" | tee -a "$OUT/summary.txt"
for tag in cfi cast nvcall nojt hardfast harddebug noinline; do grep -m2 ' error: ' "$OUT/pgo-$tag.log" | sed "s/^/  $tag: /" | tee -a "$OUT/summary.txt"; done
echo "### DONE"
