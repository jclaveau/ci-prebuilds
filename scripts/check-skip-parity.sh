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
#   3. Alpine-only entries in `<b>.titles.txt` starting with a specific
#      cluster header (`# alpine:<slug>` above them) are considered
#      justified; unjustified extras just get counted, not failed.
#
# Usage: check-skip-parity.sh [skip-list-dir] [skip-list-ubuntu-dir]
# Defaults to playwright/alpine-browsers/conformance/{skip-list,skip-list-ubuntu}.

set -eu

ALPINE_DIR="${1:-playwright/alpine-browsers/conformance/skip-list}"
UBUNTU_DIR="${2:-playwright/alpine-browsers/conformance/skip-list-ubuntu}"

BROWSERS=(chromium firefox webkit)
TYPES=(files titles)

rc=0
report=""

for b in "${BROWSERS[@]}"; do
  for t in "${TYPES[@]}"; do
    a_file="$ALPINE_DIR/$b.$t.txt"
    u_file="$UBUNTU_DIR/$b.$t.txt"

    [ -f "$a_file" ] || { echo "MISSING $a_file" >&2; rc=1; continue; }
    [ -f "$u_file" ] || { echo "MISSING $u_file" >&2; rc=1; continue; }

    # Strip comments + blanks; normalize CRLF → LF in case checkout added them
    a_entries=$(sed 's/\r$//' "$a_file" | grep -vE '^\s*(#|$)' || true)
    u_entries=$(sed 's/\r$//' "$u_file" | grep -vE '^\s*(#|$)' || true)

    a_count=$([ -z "$a_entries" ] && echo 0 || printf '%s\n' "$a_entries" | wc -l)
    u_count=$([ -z "$u_entries" ] && echo 0 || printf '%s\n' "$u_entries" | wc -l)

    # Missing = Ubuntu entries not present in Alpine
    missing=""
    if [ -n "$u_entries" ]; then
      missing=$(comm -23 <(echo "$u_entries" | sort -u) <(echo "$a_entries" | sort -u))
    fi

    if [ -n "$missing" ]; then
      report="$report
=== $b.$t.txt — MISSING BASELINE SKIPS (Alpine must include these Ubuntu skips) ==="
      report="$report
$missing"
      # Duplicate to stderr so it surfaces in CI job logs even when stdout is
      # redirected to $GITHUB_STEP_SUMMARY.
      echo "MISSING in $b.$t.txt (Alpine must include Ubuntu-baseline skips):" >&2
      echo "$missing" >&2
      rc=1
    fi

    # Alpine extras (informational)
    extras=""
    if [ -n "$a_entries" ]; then
      extras=$(comm -13 <(echo "$u_entries" | sort -u) <(echo "$a_entries" | sort -u))
    fi
    extras_count=$([ -z "$extras" ] && echo 0 || printf '%s\n' "$extras" | wc -l)

    report="$report
$b.$t.txt: alpine=$a_count ubuntu=$u_count alpine-only-extras=$extras_count"
  done
done

echo "$report"

if [ "$rc" -ne 0 ]; then
  echo ""
  echo "FAIL: Alpine skip-list is missing entries present in Ubuntu baseline." >&2
  echo "This is a fake-green risk: Alpine would report success while silently" >&2
  echo "failing tests PW-upstream marks broken. Add each missing entry to" >&2
  echo "$ALPINE_DIR/<browser>.<type>.txt." >&2
fi

exit "$rc"
