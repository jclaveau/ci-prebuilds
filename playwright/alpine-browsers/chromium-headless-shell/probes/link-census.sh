#!/bin/bash
# Post-link census of the from-source chromium binary, run in finalize between
# the final link and the strip (stage-cache-layout.sh): where the hot code
# landed, whether the PGO profile reached it, and how much of the call-graph
# profile lld had to sort with. Issue #249. Report-only: the numbers go to
# <outdir>/summary.md, the raw files beside it; nothing here fails the build.
#
# Usage: link-census.sh <work_dir> <outdir>
#   chs-hot.txt (beside this script) is the hot set: symbols of our own perf
#   profile of runtime-probe.cjs, hottest first. Names drift with the
#   chromium revision, so "hot symbols found" is reported, not assumed.
set -uo pipefail
WORK="${1:?work_dir}"; OUT="${2:?outdir}"
mkdir -p "$OUT"
HERE=$(cd "$(dirname "$0")" && pwd)
set -a; . "$WORK/versions.env"; . "$WORK/derived.env"; set +a
CHS_VER="${CHROMIUM_HEADLESS_SHELL_VERSION:?}"
VARIANT="${VARIANT:-headless}"
cd "$WORK/chromium-src/chromium-$CHS_VER" || exit 0
BUILD=out/$VARIANT
BIN="$BUILD/headless_shell"; [[ "$VARIANT" == headed ]] && BIN="$BUILD/chrome"
[[ -f "$BIN" ]] || { echo "census: $BIN missing, skipping" | tee "$OUT/summary.md"; exit 0; }
LLVM=$(ls -d /usr/lib/llvm2*/bin 2>/dev/null | sort | tail -1)
SUM="$OUT/summary.md"
{
  echo "## chromium $CHS_VER link census ($VARIANT)"
  echo
} > "$SUM"

# ---- 1. hot-set placement --------------------------------------------------
"$LLVM/llvm-nm" -n --defined-only -S "$BIN" | gzip -6 > "$OUT/symtab.nm.gz"
"$LLVM/llvm-readelf" -SW "$BIN" | grep -E '\] \.text' > "$OUT/text.txt"
cp "$HERE/chs-hot.txt" "$OUT/chs-hot.txt"
python3 - "$OUT" >> "$SUM" <<'PY'
import gzip, sys, collections
out = sys.argv[1]
syms = {}
for line in gzip.open(f"{out}/symtab.nm.gz", "rt"):
    p = line.split()
    if len(p) >= 4 and p[2] in "tT":
        syms[p[3]] = int(p[0], 16)
tb = min(syms.values())
hot = [l.strip() for l in open(f"{out}/chs-hot.txt") if l.strip()]
found = [s for s in hot if s in syms]
print(f"**Hot set**: {len(found)}/{len(hot)} symbols found ({len(syms)} text symbols in the binary).")
if not found:
    sys.exit(0)
addrs = sorted(syms[s] - tb for s in found)
mib = lambda a: a / 2**20
span90 = mib(addrs[int(len(addrs) * .9)] - addrs[0])
bands = collections.Counter(int(mib(a) / 10) * 10 for a in addrs)
print(f"Hot symbols span .text+{mib(addrs[0]):.1f}..{mib(addrs[-1]):.1f} MiB; 90% within {span90:.1f} MiB; "
      f"top 200 within {mib(max(syms[s] for s in found[:200]) - min(syms[s] for s in found[:200])):.1f} MiB.")
print()
print("| .text band (MiB) | hot symbols |")
print("|---|---|")
for b in sorted(bands):
    print(f"| +{b}–{b+10} | {bands[b]} |")
print()
print("Official's hot samples fall in ONE band; a second populated band means the CG-profile sort had no edges for those functions (see below).")
print()
PY

# ---- 2. call-graph profile coverage of the hot set ------------------------
# lld's cdsort places only sections with .llvm.call_graph_profile edges, and
# those come from PGO counts. With ThinLTO the edges live in the cache's
# native objects.
CACHE="$BUILD/thinlto-cache"
if [[ -d "$CACHE" ]]; then
  find "$CACHE" -type f -print0 \
    | xargs -0 -P "$(nproc)" -n 50 "$LLVM/llvm-readobj" --cg-profile 2>/dev/null \
    | grep -oE '(From|To): [^ ]+' | awk '{print $2}' | sort -u > "$OUT/cg-symbols.txt"
  python3 - "$OUT" >> "$SUM" <<'PY'
import sys
out = sys.argv[1]
cg = set(l.strip() for l in open(f"{out}/cg-symbols.txt"))
hot = [l.strip() for l in open(f"{out}/chs-hot.txt") if l.strip()]
top = hot[:500]
n = sum(1 for s in hot if s in cg); nt = sum(1 for s in top if s in cg)
print(f"**CG-profile coverage**: {len(cg)} symbols carry call-graph edges; hot set {n}/{len(hot)} covered, top 500 {nt}/500.")
print()
PY
else
  echo "**CG-profile coverage**: no thinlto-cache, skipped." >> "$SUM"; echo >> "$SUM"
fi

# ---- 3. PGO hash-mismatch sample ------------------------------------------
# Recompile a sample of TUs per directory with the profile warnings back on;
# "hash mismatch" = the profile has counts for the function but they were
# dropped. Counts dropped vs counts profiled says whether the hot functions
# are the ones lost (run 34811938326: layout 7% of functions, 100% of counts).
SAMPLE="${CENSUS_SAMPLE:-12}"
# -Wbackend-plugin carries the "hash mismatch" line: PGOInstrumentationUse
# reports through the backend diagnostic handler, not the frontend warnings
# (run 35035511802: 0 mismatches everywhere without it).
PGO_ON="-Wprofile-instr-unprofiled -Wprofile-instr-out-of-date -Wbackend-plugin"
PROF=$(grep -o 'pgo_data_path = "[^"]*"' "$BUILD/args.gn" | cut -d'"' -f2)
ninja -C "$BUILD" -t targets all 2>/dev/null | grep -E '\.o:' | cut -d: -f1 | sort > /tmp/all-objs.txt
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
if [[ -n "$PROF" && -f "$PROF" ]]; then
  "$LLVM/llvm-profdata" show --all-functions --counts "$PROF" 2> "$OUT/profdata.err" \
    | awk '/^  [^ ]/{name=$1} /Block counts:/{gsub(/[\[\],]/," "); m=0; for(i=3;i<=NF;i++) if($i+0>m) m=$i+0; print name, m}' \
    | sed 's/:$//' | sort -k1,1 > /tmp/profile-counts.txt
  echo "profile: $(wc -l < /tmp/profile-counts.txt) functions with block counts ($PROF)" | tee -a "$OUT/profdata.err"
  {
    echo "**PGO hash mismatch** ($SAMPLE TUs per dir; counts = hottest block count of each function):"
    echo
    echo "| dir | TUs | profiled fns | mismatched | fn% | counts profiled | counts dropped | cnt% |"
    echo "|---|---|---|---|---|---|---|---|"
  } >> "$SUM"
  for dir in third_party/blink/renderer/core/layout third_party/blink/renderer/core/dom \
             third_party/blink/renderer/core/css third_party/blink/renderer/platform base; do
    tag=$(echo "$dir" | tr / _)
    printf "%s\n" "$dir"/*.cc | grep -vE '(_unittest|_test|_perftest|_fuzzer|test_support|_browsertest)\.cc$' \
      | head -n "$SAMPLE" | while read -r src; do obj_for_src "$src" || true; done > "/tmp/objs-$tag.txt"
    rm -rf "/tmp/pgo-$tag"; mkdir -p "/tmp/pgo-$tag"
    xargs -P "$(nproc)" -I{} bash -c '
      obj="$1"; tag="$2"; build="$3"; pgo_on="$4"
      line=$(ninja -C "$build" -t commands "$obj" 2>/dev/null | tail -1 | sed "s/^sccache //")
      [ -n "$line" ] || exit 0
      line=$(printf "%s" "$line" | sed -E "s# -o [^ ]+# -o /tmp/pgo-$tag/$(echo "$obj" | tr / _)#")
      { echo "### $obj"; (cd "$build" && eval "$line $pgo_on" 2>&1 || true); } > "/tmp/pgo-$tag/$(echo "$obj" | tr / _).log"
    ' _ {} "$tag" "$BUILD" "$PGO_ON" < "/tmp/objs-$tag.txt"
    cat "/tmp/pgo-$tag"/*.log > "$OUT/pgo-$tag.log" 2>/dev/null
    grep -o 'hash mismatch) [^ ]* Hash = [0-9]* up to [0-9]*' "$OUT/pgo-$tag.log" | awk '{print $3, $NF}' | sort -u > "$OUT/mismatch-$tag.txt"
    # functions of the sampled objects that the profile knows
    for o in $(cat "/tmp/objs-$tag.txt"); do "$LLVM/llvm-nm" --defined-only "$BUILD/$o" 2>/dev/null | awk '$2 ~ /[tT]/ {print $3}'; done | sort -u > "/tmp/defined-$tag.txt"
    awk 'NR==FNR{c[$1]=$2; next} ($1 in c){print $1, c[$1]}' /tmp/profile-counts.txt "/tmp/defined-$tag.txt" > "$OUT/profiled-$tag.txt"
    tus=$(wc -l < "/tmp/objs-$tag.txt"); prof=$(wc -l < "$OUT/profiled-$tag.txt"); mis=$(wc -l < "$OUT/mismatch-$tag.txt")
    cp=$(awk '{s+=$2} END{print s+0}' "$OUT/profiled-$tag.txt"); cd_=$(awk '{s+=$2} END{print s+0}' "$OUT/mismatch-$tag.txt")
    printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' "$dir" "$tus" "$prof" "$mis" \
      "$(awk -v a="$mis" -v b="$prof" 'BEGIN{printf "%.1f%%", b?100*a/b:0}')" "$cp" "$cd_" \
      "$(awk -v a="$cd_" -v b="$cp" 'BEGIN{printf "%.1f%%", b?100*a/b:0}')" >> "$SUM"
  done
  echo >> "$SUM"
else
  echo "**PGO hash mismatch**: no pgo_data_path in args.gn, skipped." >> "$SUM"; echo >> "$SUM"
fi
cat "$SUM"
