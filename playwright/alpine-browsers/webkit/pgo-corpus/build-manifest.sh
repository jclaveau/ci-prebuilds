#!/usr/bin/env bash
# Generate the WebKit PGO training manifest from the source tree it will run
# against, instead of hardcoding a page list in train.html.
#
# The corpus has to follow PW_WEBKIT_SHA. A hardcoded list outlives the
# checkout it was written for, and an entry whose file has since moved 404s
# and trains nothing while looking, from outside, exactly like an entry that
# ran — the same silent failure `apply-and-build-port.sh` already guards the
# whole corpus against with its smoke-vs-corpus count ratio. Discovering the
# pages from $SRC keeps the list and the tree in lockstep for free. Firefox's
# corpus arm reached the same conclusion from the other side: PR #307
# generated its corpus FROM runtime-probe.cjs so the trained pages and the
# graded kernels could not drift apart.
#
# Only depth-1 `*.html` under the named directories. Those are the test pages;
# the subdirectories hold their resources, plus a few grouped suites that need
# their own driver. Anything listed in PerformanceTests/Skipped is dropped —
# upstream skips it because it hangs or crashes, and either way it would spend
# corpus budget without contributing counts.
#
# The directory order is the order the driver walks, and it is deliberate:
# the rows perf-gate-webkit actually grades come first, so a budget that runs
# out mid-pass truncates the least relevant tail. (The driver sizes its dwell
# to fit one full pass, so this only matters if a page overruns.)
#
# Usage: build-manifest.sh <performance_tests_dir> <out_json> <budget_seconds>

set -eu

PERF_DIR="${1:?usage: build-manifest.sh <performance_tests_dir> <out_json> <budget_seconds>}"
OUT="${2:?usage: build-manifest.sh <performance_tests_dir> <out_json> <budget_seconds>}"
BUDGET_SECONDS="${3:?usage: build-manifest.sh <performance_tests_dir> <out_json> <budget_seconds>}"

# Share of the budget the benchmark-harness entries keep. The rest is split
# evenly across the plain PerfTestRunner pages. This is the one knob that
# decides "deep on one benchmark" vs "broad over many" — the whole subject of
# this arm — so it stays visible here rather than inside the driver.
DEEP_SHARE="${PGO_CORPUS_DEEP_SHARE:-0.25}"

ENTRY_DIRS="Layout Parser DOM CSS ContentVisibility Canvas Paint Bindings SVG ShadowDOM Animation Containment Interactive Intl Media Mutation"

[ -d "$PERF_DIR" ] || { echo "ERROR: $PERF_DIR is not a directory" >&2; exit 1; }

# Skipped holds both file paths and bare directory names. Both are matched as
# path prefixes, which is what upstream's own runner does with it.
SKIPPED_LIST=""
if [ -f "$PERF_DIR/Skipped" ]; then
  SKIPPED_LIST=$(sed 's/\r$//' "$PERF_DIR/Skipped" | grep -vE '^\s*(#|$)' || true)
fi

is_skipped() {
  local path="$1" entry
  [ -n "$SKIPPED_LIST" ] || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$path" in
      "$entry"|"$entry"/*) return 0 ;;
    esac
  done <<EOF
$SKIPPED_LIST
EOF
  return 1
}

# `startTest` is benchmark-report.js's entry point, shared by Speedometer and
# StyleBench (a Speedometer fork). It is not reachable by navigation: that
# file auto-runs only under DumpRenderTree or the '#webkit' hash, and the hash
# path pulls in PerfTestRunner, which is not what a browser run exercises.
deep_entry() {
  local rel="$1" fn="$2"
  # The url carries a query string; the existence check must not.
  [ -f "$PERF_DIR/${rel%%\?*}" ] || return 0
  printf '    {"url": "/%s", "startFunction": "%s"},\n' "$rel" "$fn" >> "$OUT"
  DEEP_COUNT=$((DEEP_COUNT + 1))
}

: > "$OUT"
printf '{\n  "budgetMs": %d,\n  "deepShare": %s,\n  "entries": [\n' \
  "$((BUDGET_SECONDS * 1000))" "$DEEP_SHARE" > "$OUT"

DEEP_COUNT=0
FLAT_COUNT=0
deep_entry "Speedometer2.1/index.html?iterationCount=5" startTest
deep_entry "StyleBench/index.html" startTest

for dir in $ENTRY_DIRS; do
  [ -d "$PERF_DIR/$dir" ] || continue
  for page in "$PERF_DIR/$dir"/*.html; do
    [ -f "$page" ] || continue
    rel="$dir/$(basename "$page")"
    is_skipped "$rel" && continue
    printf '    {"url": "/%s"},\n' "$rel" >> "$OUT"
    FLAT_COUNT=$((FLAT_COUNT + 1))
  done
done

if [ "$((DEEP_COUNT + FLAT_COUNT))" -eq 0 ]; then
  echo "ERROR: no corpus pages found under $PERF_DIR — the tree layout moved" >&2
  exit 1
fi
if [ "$DEEP_COUNT" -eq 0 ]; then
  echo "ERROR: no benchmark-harness entry survived — Speedometer2.1 is gone" >&2
  exit 1
fi

# Trailing comma: JSON has no tolerance for one, and every entry above writes
# its own. Drop it from the last line rather than special-casing each writer.
sed -i '$ s/,$//' "$OUT"
printf '  ]\n}\n' >> "$OUT"

echo "corpus manifest: $DEEP_COUNT benchmark-harness + $FLAT_COUNT PerfTestRunner pages, ${BUDGET_SECONDS}s budget, deep share $DEEP_SHARE"
