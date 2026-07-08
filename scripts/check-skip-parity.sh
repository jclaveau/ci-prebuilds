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
# by side. Missing-baseline details appear as a separate section below the
# table when the check fails.
#
# Usage: check-skip-parity.sh [skip-list-dir] [skip-list-ubuntu-dir]
# Defaults to playwright/alpine-browsers/conformance/{skip-list,skip-list-ubuntu}.

set -eu

ALPINE_DIR="${1:-playwright/alpine-browsers/conformance/skip-list}"
UBUNTU_DIR="${2:-playwright/alpine-browsers/conformance/skip-list-ubuntu}"

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

    # Strip comments + blanks; normalize CRLF → LF in case checkout added them
    a_entries=$(sed 's/\r$//' "$a_file" | grep -vE '^\s*(#|$)' || true)
    u_entries=$(sed 's/\r$//' "$u_file" | grep -vE '^\s*(#|$)' || true)

    A[$b.$t]=$([ -z "$a_entries" ] && echo 0 || printf '%s\n' "$a_entries" | wc -l)
    U[$b.$t]=$([ -z "$u_entries" ] && echo 0 || printf '%s\n' "$u_entries" | wc -l)

    # Missing = Ubuntu entries not present in Alpine
    missing=""
    if [ -n "$u_entries" ]; then
      missing=$(comm -23 <(printf '%s\n' "$u_entries" | sort -u) <(printf '%s\n' "$a_entries" | sort -u))
    fi
    MISS[$b.$t]="$missing"

    # Alpine extras (informational)
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
echo "Alpine conformance skip-lists must be a **superset** of the Ubuntu"
echo "baseline. Alpine extras (musl-specific gaps) are counted but allowed."
echo ""
echo "| Browser | files (A / U / +alpine-only) | titles (A / U / +alpine-only) | status |"
echo "|---|---|---|---|"

for b in "${BROWSERS[@]}"; do
  af=${A[$b.files]}; uf=${U[$b.files]}; ef=${E[$b.files]}
  at=${A[$b.titles]}; ut=${U[$b.titles]}; et=${E[$b.titles]}
  status="✓"
  if [ -n "${MISS[$b.files]}" ] || [ -n "${MISS[$b.titles]}" ]; then
    status="✗ **FAIL**"
  fi
  printf "| %s | %s / %s / +%s | %s / %s / +%s | %s |\n" \
    "$b" "$af" "$uf" "$ef" "$at" "$ut" "$et" "$status"
done

# ── Failure detail ────────────────────────────────────────────────────
if [ "$rc" -ne 0 ]; then
  echo ""
  echo "### ✗ Missing baseline skips"
  echo ""
  echo "Alpine must include every Ubuntu-baseline skip. Add the entries below"
  echo "to the matching \`$ALPINE_DIR/<browser>.<type>.txt\` file, then re-run."
  echo ""
  for b in "${BROWSERS[@]}"; do
    for t in "${TYPES[@]}"; do
      m="${MISS[$b.$t]}"
      [ -z "$m" ] && continue
      echo "**$b.$t.txt** — missing $(printf '%s\n' "$m" | wc -l) entr$([ "$(printf '%s\n' "$m" | wc -l)" -eq 1 ] && echo y || echo ies):"
      echo ""
      echo "\`\`\`"
      echo "$m"
      echo "\`\`\`"
      echo ""
      # Also duplicate to stderr so CI job logs surface it (workflow may
      # redirect stdout to $GITHUB_STEP_SUMMARY).
      echo "MISSING in $b.$t.txt:" >&2
      echo "$m" >&2
    done
  done
fi

exit "$rc"
