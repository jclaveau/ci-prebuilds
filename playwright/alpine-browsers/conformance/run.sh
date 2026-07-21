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

# Firefox on musl: Juggler's XPCOM component-line-handler registers under
# category name `m-remote`, which collides with Mozilla's own RemoteAgent
# (same category). JugglerFactory only instantiates as a side-effect of
# RemoteAgent activating — so `firefox.launch()` with only `-juggler-pipe`
# hangs at handshake (fd4 never writes "Juggler listening to the pipe").
#
# The published smoke workaround (playwright/alpine-browsers/firefox/smoke/
# launch.cjs:23-25) is to pass `--remote-debugging-port=0`, which wakes
# RemoteAgent → Juggler activates. Inject the same arg into the upstream
# tests/library/playwright.config.ts firefox launchOptions so every project
# picks it up.
# chromium: --run-all-compositor-stages-before-draw + --disable-new-content-
# rendering-timeout fix `screencast › should capture navigation` on CI's
# software-GL (SwiftShader). That test records a cross-process black→gray nav
# and asserts the LAST frame isAlmostGray; late in a big shard the accumulated
# software-GL compositor state holds the old BLACK content past context.close()
# → black last frame. The two flags together (neither alone) force the new gray
# to composite synchronously before the screencast frame emits. Validated on the
# exact --shard=17/20 repro: neither flag alone passes, both → 113/113.
sed -i 's|executablePath,|executablePath,\n        args: browserName === "firefox" ? ["--remote-debugging-port=0"] : browserName === "chromium" ? ["--run-all-compositor-stages-before-draw", "--disable-new-content-rendering-timeout"] : undefined,|' \
  tests/library/playwright.config.ts

# Upstream's config only builds ${browser}-library + ${browser}-page projects
# (testDir library/ + page/). tests/stress/ + tests/extension/ use the same
# tests/config/baseTest but have no project, so they never run. Inject a
# ${browser}-stress + ${browser}-extension project (same projectTemplate → same
# launchOptions/browserName) so consumers get parity on those surfaces too.
# Extension is a chromium-only feature (specs self-skip on FF/WK + on the
# headless-shell channel); stress heap.spec is browser-agnostic.
sed -i 's#  config.projects.push(pageProject);#  config.projects.push(pageProject);\n  config.projects.push({ name: browserName + "-stress", testDir: path.join(testDir, "stress"), ...projectTemplate });\n  config.projects.push({ name: browserName + "-extension", testDir: path.join(testDir, "extension"), ...projectTemplate });#' \
  tests/library/playwright.config.ts
grep -A3 "launchOptions:" tests/library/playwright.config.ts | head -6

# trace-viewer.spec.ts "should filter actions by text" captures
# `fullCount = actionTitles.count()` immediately after showTraceViewer, before the
# trace-derived action tree finishes rendering (the Filter searchbox renders faster
# than the list). On the slower Alpine viewer fullCount races to 0 → the later
# `filtered < fullCount` becomes `< 0` and fails DETERMINISTICALLY. Upstream PW test
# race (not a browser gap — the browser renders + filters correctly). Add the missing
# wait for the action list to render before the baseline count. Strengthens the
# baseline capture; does NOT weaken the assertion. Diagnosed + validated 2026-07-21.
sed -i 's#  const fullCount = await traceViewer.actionTitles.count();#  await traceViewer.page.locator(".action-title").first().waitFor();\n  const fullCount = await traceViewer.actionTitles.count();#' \
  tests/library/trace-viewer.spec.ts

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

TIMEOUT_FLAG=""

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
RC_STRESS=0
RC_EXTENSION=0

run_one() {
  CONFIG="$1"; PROJECT="$2"; LABEL="$3"
  echo "==== ${LABEL} — shard ${SHARD}/${SHARD_TOTAL} ===="
  # Tee stdout to a per-suite log so the runtime-parity gate can grep pass
  # /fail/skip counts without pulling GH logs by API. `pipefail` propagates
  # the playwright exit code past `tee`.
  LOG="$REPORT_DIR/${LABEL}.log"
  # PW's inspector / recorder / trace-viewer / selector-generator / slowmo /
  # debug-controller subsystems launch an INTERNAL headed chromium as the
  # recorder UI harness (independent of the browser under test). It fails
  # under headless Alpine without X. Wrap with `xvfb-run -a` so those specs
  # can run — the browser-under-test still runs headless via its own launcher.
  # `xvfb-run` is a no-op cost when a DISPLAY is already set.
  set -o pipefail
  if [ -n "$GREP_INVERT" ]; then
    xvfb-run -a npx playwright test \
      --config="$CONFIG" \
      --project="$PROJECT" \
      --shard="${SHARD}/${SHARD_TOTAL}" \
      --reporter=line,html \
      --retries=2 \
      $TIMEOUT_FLAG \
      $GREP_INVERT "$TITLE_PATTERNS" 2>&1 | tee "$LOG"
  else
    xvfb-run -a npx playwright test \
      --config="$CONFIG" \
      --project="$PROJECT" \
      --shard="${SHARD}/${SHARD_TOTAL}" \
      --reporter=line,html \
      --retries=2 \
      $TIMEOUT_FLAG 2>&1 | tee "$LOG"
  fi
  RC=$?
  set +o pipefail

  # Distill the tail of the line reporter into a stable `stats.txt` line
  # for the runtime-parity aggregator. Matches PW's summary format:
  #   `  <N> passed (<time>)` | `  <N> failed` | `  <N> skipped`
  #
  # PW's line reporter emits progress with ANSI cursor-move sequences
  # (`ESC[1A`, `ESC[2K`) prepended to each terminal-refresh line — including
  # the final summary row. `^\s+` in the grep pattern never matches a line
  # that starts with `\e[1A\e[2K`. Strip ANSI escape sequences before the
  # summary grep so pass/fail counts land in stats.txt reliably. Prior bug
  # per-run 29273524842 shard 1: log has `95 passed (17.0s)` but stats.txt
  # got passed=0 → runtime-parity aggregator undercounted the whole leg.
  strip_ansi() { sed -E 's/\x1B\[[0-9;?]*[a-zA-Z]//g'; }
  passed=$(strip_ansi < "$LOG" | grep -oE '^\s*[0-9]+ passed' | tail -1 | grep -oE '[0-9]+' || echo 0)
  failed=$(strip_ansi < "$LOG" | grep -oE '^\s*[0-9]+ failed' | tail -1 | grep -oE '[0-9]+' || echo 0)
  skipped=$(strip_ansi < "$LOG" | grep -oE '^\s*[0-9]+ skipped' | tail -1 | grep -oE '[0-9]+' || echo 0)
  echo "browser=${BROWSER} shard=${SHARD}/${SHARD_TOTAL} suite=${LABEL} passed=${passed} failed=${failed} skipped=${skipped}" \
    >> "$REPORT_DIR/stats.txt"

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

run_one tests/library/playwright.config.ts "${BROWSER}-stress" stress
RC_STRESS=$?

run_one tests/library/playwright.config.ts "${BROWSER}-extension" extension
RC_EXTENSION=$?

set -e

echo "==== Shard ${SHARD}/${SHARD_TOTAL} done — library rc=${RC_LIB}, page rc=${RC_PAGE}, stress rc=${RC_STRESS}, extension rc=${RC_EXTENSION} ===="

# Fail the shard if any suite failed. Caller's matrix has fail-fast: false
# so other shards keep running; aggregator job sees the per-shard outcome.
[ "$RC_LIB" -eq 0 ] && [ "$RC_PAGE" -eq 0 ] && [ "$RC_STRESS" -eq 0 ] && [ "$RC_EXTENSION" -eq 0 ]
