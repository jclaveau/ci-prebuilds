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
#   SKIP_LIST     — path inside the runner to a skip-list file; one regex per
#                   line, # comments stripped. Joined with `|` into
#                   `--grep-invert`. Defaults to /conformance/skip-list/$BROWSER.txt.
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

SKIP_LIST="${SKIP_LIST:-/conformance/skip-list/${BROWSER}.txt}"
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

# Compose --grep-invert from skip-list, if any. Skip-list lines are PW test
# full-title regexes; one per line; # comments and blanks ignored. Joined with
# `|` into a single regex passed to --grep-invert. Empty list → no flag added.
GREP_INVERT=""
if [ -f "$SKIP_LIST" ]; then
  PATTERNS=$(grep -vE '^\s*(#|$)' "$SKIP_LIST" | paste -sd'|' -)
  if [ -n "$PATTERNS" ]; then
    GREP_INVERT="--grep-invert"
    echo "==== Skip-list active ($SKIP_LIST): $(echo "$PATTERNS" | tr '|' '\n' | wc -l) patterns ===="
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
      $GREP_INVERT "$PATTERNS"
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
