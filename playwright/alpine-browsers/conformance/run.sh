#!/bin/sh
# Run microsoft/playwright tests/library + tests/page against our musl-built
# browser artifact. Goal: drop-in replacement parity — pass the same suite PW
# maintainers use to certify a browser build "PW-compatible."
#
# Required env:
#   BROWSER       — chromium | firefox | webkit
#                   (selects PW project filter + which artifact is staged)
#   PW_VERSION    — PW tag to clone (e.g. 1.59.1); MUST match the artifact's
#                   browsers.json revision (producer build resolves this).
#   SHARD         — current shard index (1..SHARD_TOTAL)
#   SHARD_TOTAL   — total shard count (default 10, matches upstream PW CI)
#
# Optional env:
#   SKIP_DIR      — path inside the runner to per-browser skip lists; defaults
#                   to /conformance/skip-list. Two files per browser:
#                     <BROWSER>.files.txt   — POSIX-extended regexes matching
#                       spec FILE paths (relative to pw-src/). Files matching
#                       are deleted from disk before tests run. Use this for
#                       structural divergences where an entire spec file
#                       cannot run (UI subsystem missing, encoder absent,
#                       etc.).
#                     <BROWSER>.titles.txt  — JS regexes matching test title
#                       paths (NOT file paths — PW's --grep matches
#                       `test.titlePath().join(' › ')`, which excludes the
#                       spec file path). Joined with `|` into a single regex
#                       passed to --grep-invert. Use for individual real
#                       conformance gaps.
#
# Output: /conformance/report-$BROWSER-$SHARD/ with the HTML reporter dump,
# plus a line-protocol summary on stdout for the aggregator job.

set -eu

: "${BROWSER:?BROWSER must be set}"
: "${PW_VERSION:?PW_VERSION must be set}"
: "${SHARD:?SHARD must be set}"
: "${SHARD_TOTAL:?SHARD_TOTAL must be set}"

case "$BROWSER" in
  chromium|firefox|webkit) ;;
  *) echo "BROWSER must be one of: chromium, firefox, webkit (got: $BROWSER)" >&2; exit 1 ;;
esac

SKIP_DIR="${SKIP_DIR:-/conformance/skip-list}"
FILES_LIST="$SKIP_DIR/${BROWSER}.files.txt"
TITLES_LIST="$SKIP_DIR/${BROWSER}.titles.txt"
PW_TAG="v${PW_VERSION}"
PW_SRC="${PW_SRC:-/pw-src}"
REPORT_DIR="/conformance/report-${BROWSER}-${SHARD}"
mkdir -p "$REPORT_DIR"

echo "==== Cloning microsoft/playwright@${PW_TAG} ===="
mkdir -p "$PW_SRC"
git clone --depth 1 --branch "$PW_TAG" \
  https://github.com/microsoft/playwright.git "$PW_SRC"

cd "$PW_SRC"

echo "==== npm ci (cold install, ~3-5min) ===="
npm ci --no-audit --no-fund --prefer-offline

echo "==== npm run build ===="
npm run build

# Apply files.txt — delete every spec file whose path matches a pattern.
# Each pattern is a POSIX-extended regex anchored implicitly (we use grep -E).
# Patterns operate on paths relative to PW_SRC, e.g. `tests/library/inspector/`.
if [ -f "$FILES_LIST" ]; then
  FILE_PATTERNS=$(grep -vE '^\s*(#|$)' "$FILES_LIST" | paste -sd'|' -)
  if [ -n "$FILE_PATTERNS" ]; then
    echo "==== Spec-file skip-list active ($FILES_LIST): $(echo "$FILE_PATTERNS" | tr '|' '\n' | wc -l) patterns ===="
    REMOVED_COUNT=0
    # Iterate every .spec.ts under tests/ (the library + page suites).
    find tests -type f -name '*.spec.ts' -print | grep -E "$FILE_PATTERNS" | while read -r spec; do
      rm -f "$spec"
      echo "  removed: $spec"
      REMOVED_COUNT=$((REMOVED_COUNT + 1))
    done || true
  fi
fi

# Compose --grep-invert from titles.txt. Titles are matched against PW's
# `test.titlePath().join(' › ')` — describe-chain + test name, no file path.
GREP_INVERT=""
TITLE_PATTERNS=""
if [ -f "$TITLES_LIST" ]; then
  TITLE_PATTERNS=$(grep -vE '^\s*(#|$)' "$TITLES_LIST" | paste -sd'|' -)
  if [ -n "$TITLE_PATTERNS" ]; then
    GREP_INVERT="--grep-invert"
    echo "==== Title skip-list active ($TITLES_LIST): $(echo "$TITLE_PATTERNS" | tr '|' '\n' | wc -l) patterns ===="
  fi
fi

export PWTEST_UNDER_TEST=1

# Upstream PW's tests/library/playwright.config.ts is the single config for
# BOTH the library suite and the page suite — it declares per-browser projects
# named `${browser}-library` (specs in tests/library/) AND `${browser}-page`
# (specs in tests/page/). There is no tests/page/playwright.config.ts in
# upstream. Run the same config twice, filtered by --project.
#
# --reporter=html (config-default) writes to playwright-report/; we move it
# into REPORT_DIR after each run so both library + page outputs survive.

set +e
RC_LIB=0
RC_PAGE=0

run_one() {
  CONFIG="$1"; PROJECT="$2"; LABEL="$3"
  echo "==== ${LABEL} — shard ${SHARD}/${SHARD_TOTAL} ===="
  if [ -n "$GREP_INVERT" ]; then
    npx playwright test \
      --config="$CONFIG" \
      --project="$PROJECT" \
      --shard="${SHARD}/${SHARD_TOTAL}" \
      --reporter=line,html \
      $GREP_INVERT "$TITLE_PATTERNS"
  else
    npx playwright test \
      --config="$CONFIG" \
      --project="$PROJECT" \
      --shard="${SHARD}/${SHARD_TOTAL}" \
      --reporter=line,html
  fi
  RC=$?
  # html reporter default output path is playwright-report/; move it.
  if [ -d "$PW_SRC/playwright-report" ]; then
    mv "$PW_SRC/playwright-report" "$REPORT_DIR/${LABEL}-report"
  fi
  return "$RC"
}

run_one tests/library/playwright.config.ts "${BROWSER}-library" library
RC_LIB=$?

run_one tests/library/playwright.config.ts "${BROWSER}-page" page
RC_PAGE=$?

set -e

echo "==== Shard ${SHARD}/${SHARD_TOTAL} done — library rc=${RC_LIB}, page rc=${RC_PAGE} ===="

# Fail the shard if either suite failed. Caller's matrix has fail-fast: false
# so other shards keep running; aggregator job sees the per-shard outcome.
[ "$RC_LIB" -eq 0 ] && [ "$RC_PAGE" -eq 0 ]
