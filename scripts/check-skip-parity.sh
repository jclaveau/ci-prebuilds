#!/usr/bin/env bash
# Assert Alpine conformance skip-lists ⊇ Ubuntu baseline skip-lists per browser.
#
# Rationale: PW's Ubuntu-based reference build is the bar. Alpine may skip MORE
# (musl-specific gaps) but must never skip LESS — any PW-upstream-known fail
# skipped on Ubuntu must also be skipped on Alpine. Otherwise Alpine can report
# "green" while silently regressing tests Ubuntu correctly marks broken.
#
# Rules:
#   1. Every non-comment line in `skip-list-ubuntu/<b>.{files,titles}.txt`
#      MUST appear (byte-identical) in `skip-list/<b>.{files,titles}.txt`.
#      Violation = FAIL (missing baseline skip on Alpine).
#   2. Alpine extras are allowed (informational count reported).
#
# Output: GitHub-flavored markdown, one browser per row, files + titles side
# by side. Header line surfaces the PW version + each browser's exact
# revision + browserVersion pin (fetched from `playwright-core@$PW_VERSION`'s
# `browsers.json` on unpkg). Missing-baseline details appear as a separate
# section below the table when the check fails.
#
# Usage: check-skip-parity.sh [skip-list-dir] [skip-list-ubuntu-dir]
# Env:
#   PW_VERSION     — PW version pin. Defaults to reading versions.env.
#   SKIP_VERSIONS  — set to 1 to skip the browsers.json fetch (offline mode).

set -eu

ALPINE_DIR="${1:-playwright/alpine-browsers/conformance/skip-list}"
UBUNTU_DIR="${2:-playwright/alpine-browsers/conformance/skip-list-ubuntu}"

# ── Resolve PW + browser versions ────────────────────────────────────
: "${PW_VERSION:=}"
if [ -z "$PW_VERSION" ] && [ -r "playwright/alpine-browsers/versions.env" ]; then
  PW_VERSION=$(awk -F= '$1=="PW_VERSION"{gsub(/"/,"",$2); print $2; exit}' \
    playwright/alpine-browsers/versions.env)
fi

declare -A REV VER
if [ -n "$PW_VERSION" ] && [ "${SKIP_VERSIONS:-0}" != "1" ]; then
  BROWSERS_JSON=$(curl -fsSL "https://unpkg.com/playwright-core@${PW_VERSION}/browsers.json" 2>/dev/null || true)
  if [ -n "$BROWSERS_JSON" ] && command -v jq >/dev/null; then
    for b in chromium firefox webkit; do
      REV[$b]=$(jq -r ".browsers[] | select(.name==\"$b\") | .revision" <<<"$BROWSERS_JSON")
      VER[$b]=$(jq -r ".browsers[] | select(.name==\"$b\") | .browserVersion" <<<"$BROWSERS_JSON")
    done
  fi
fi

BROWSERS=(chromium firefox webkit)
TYPES=(files titles)

rc=0
declare -A A U E MISS

for b in "${BROWSERS[@]}"; do
  for t in "${TYPES[@]}"; do
    a_file="$ALPINE_DIR/$b.$t.txt"
    u_file="$UBUNTU_DIR/$b.$t.txt"

    [ -f "$a_file" ] || { echo "MISSING file: $a_file" >&2; rc=1; continue; }
    [ -f "$u_file" ] || { echo "MISSING file: $u_file" >&2; rc=1; continue; }

    a_entries=$(sed 's/\r$//' "$a_file" | grep -vE '^\s*(#|$)' || true)
    u_entries=$(sed 's/\r$//' "$u_file" | grep -vE '^\s*(#|$)' || true)

    A[$b.$t]=$([ -z "$a_entries" ] && echo 0 || printf '%s\n' "$a_entries" | wc -l)
    U[$b.$t]=$([ -z "$u_entries" ] && echo 0 || printf '%s\n' "$u_entries" | wc -l)

    missing=""
    if [ -n "$u_entries" ]; then
      missing=$(comm -23 <(printf '%s\n' "$u_entries" | sort -u) <(printf '%s\n' "$a_entries" | sort -u))
    fi
    MISS[$b.$t]="$missing"

    extras=""
    if [ -n "$a_entries" ]; then
      extras=$(comm -13 <(printf '%s\n' "$u_entries" | sort -u) <(printf '%s\n' "$a_entries" | sort -u))
    fi
    E[$b.$t]=$([ -z "$extras" ] && echo 0 || printf '%s\n' "$extras" | wc -l)

    [ -n "$missing" ] && rc=1
  done
done

# ── Markdown tally ────────────────────────────────────────────────────
echo "## Skip-list parity"
echo ""
if [ -n "$PW_VERSION" ]; then
  echo "Playwright test source: [\`microsoft/playwright@v${PW_VERSION}\`](https://github.com/microsoft/playwright/tree/v${PW_VERSION}/tests) — \`tests/library\` + \`tests/page\` suites."
else
  echo "Playwright test source: microsoft/playwright (PW_VERSION not resolved)."
fi
echo ""
echo "Alpine skip-lists must be a **superset** of the Ubuntu baseline. Alpine"
echo "extras (musl-specific gaps) are counted but allowed."
echo ""
echo "| Browser | version pin | files (A / U / +alpine-only) | titles (A / U / +alpine-only) | status |"
echo "|---|---|---|---|---|"

for b in "${BROWSERS[@]}"; do
  af=${A[$b.files]}; uf=${U[$b.files]}; ef=${E[$b.files]}
  at=${A[$b.titles]}; ut=${U[$b.titles]}; et=${E[$b.titles]}
  status="✓"
  if [ -n "${MISS[$b.files]}" ] || [ -n "${MISS[$b.titles]}" ]; then
    status="✗ **FAIL**"
  fi
  ver_cell="—"
  if [ -n "${VER[$b]:-}" ] && [ -n "${REV[$b]:-}" ]; then
    ver_cell="\`${VER[$b]}\` (rev \`${REV[$b]}\`)"
  fi
  printf "| %s | %s | %s / %s / +%s | %s / %s / +%s | %s |\n" \
    "$b" "$ver_cell" "$af" "$uf" "$ef" "$at" "$ut" "$et" "$status"
done

# ── Failure detail ────────────────────────────────────────────────────
if [ "$rc" -ne 0 ]; then
  echo ""
  echo "### ✗ Missing baseline skips"
  echo ""
  echo "Alpine must include every Ubuntu-baseline skip. Add the entries below"
  echo "to the matching \`$ALPINE_DIR/<browser>.<type>.txt\` file, then re-run."
  echo ""
  gh_base=""
  [ -n "$PW_VERSION" ] && gh_base="https://github.com/microsoft/playwright/tree/v${PW_VERSION}"
  for b in "${BROWSERS[@]}"; do
    for t in "${TYPES[@]}"; do
      m="${MISS[$b.$t]}"
      [ -z "$m" ] && continue
      n=$(printf '%s\n' "$m" | wc -l)
      echo "**$b.$t.txt** — missing $n entr$([ "$n" -eq 1 ] && echo y || echo ies):"
      echo ""
      echo "\`\`\`"
      echo "$m"
      echo "\`\`\`"
      if [ -n "$gh_base" ]; then
        echo ""
        if [ "$t" = "files" ]; then
          echo "Look up in PW source: [\`tests/library\`](${gh_base}/tests/library) · [\`tests/page\`](${gh_base}/tests/page)"
        else
          # Link a code-search URL scoped to PW at pinned tag for each title
          while IFS= read -r line; do
            [ -z "$line" ] && continue
            # Strip regex meta to get a plain search phrase; drop trailing anchor
            phrase=$(echo "$line" | sed -E 's/\\([.\\])/\1/g; s/\\s\*\$$//; s/\$$//')
            q=$(printf '%s' "$phrase" | jq -sRr @uri)
            echo "- [\`$phrase\`](https://github.com/search?q=repo%3Amicrosoft%2Fplaywright+%22${q}%22+path%3Atests&type=code)"
          done <<<"$m"
        fi
      fi
      echo ""
      echo "MISSING in $b.$t.txt:" >&2
      echo "$m" >&2
    done
  done
fi

exit "$rc"
