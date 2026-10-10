#!/usr/bin/env bash
# Unit test for the Alpine-vs-Ubuntu skip-list superset gate.
#
# Exists for the capability-gated list: run.sh applies
# `skip-list/<b>.needs-headed.titles.txt` only when the artifact carries no
# headed binary, so those titles are skipped on the WPE-only build we ship but
# live outside `<b>.titles.txt` on purpose — a GTK build must still run them.
# The gate has to count them, and must keep failing for a title that is
# genuinely absent, or "count needs-headed too" becomes "stop checking titles".

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
GATE="$ROOT/scripts/check-skip-parity.sh"

failures=0
checks=0
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# The gate reads all three browsers, so every case needs the full file set.
seed_lists() {
  local case_dir="$1"
  local b
  mkdir -p "$case_dir/alp" "$case_dir/ubu"
  for b in chromium firefox webkit; do
    : > "$case_dir/alp/$b.files.txt"
    : > "$case_dir/alp/$b.titles.txt"
    : > "$case_dir/ubu/$b.files.txt"
    : > "$case_dir/ubu/$b.titles.txt"
  done
}

# $1 label, $2 expected rc, $3 expected output substring, rest: `file:line`
# where file is a path under the case dir, e.g. `ubu/webkit.titles.txt`.
expect() {
  local label="$1" want_rc="$2" want_text="$3"; shift 3
  local case_dir="$workdir/$checks"
  seed_lists "$case_dir"
  local spec file line
  for spec in "$@"; do
    file=${spec%%:*}; line=${spec#*:}
    printf '%s\n' "$line" >> "$case_dir/$file"
  done

  local out got=0
  out=$(SKIP_VERSIONS=1 PW_VERSION='' "$GATE" "$case_dir/alp" "$case_dir/ubu" 2>&1) || got=$?
  checks=$((checks + 1))
  if [ "$got" != "$want_rc" ]; then
    echo "FAIL: $label — exit $got, wanted $want_rc" >&2
    echo "$out" | sed 's/^/    /' >&2
    failures=$((failures + 1))
    return
  fi
  if ! printf '%s' "$out" | grep -qF "$want_text"; then
    echo "FAIL: $label — output does not contain '$want_text'" >&2
    echo "$out" | sed 's/^/    /' >&2
    failures=$((failures + 1))
  fi
}

TITLE='should throw a friendly error if its headed and there is no xserver on linux running$'

expect "a baseline title present on Alpine passes" 0 "| webkit |" \
  "ubu/webkit.titles.txt:$TITLE" "alp/webkit.titles.txt:$TITLE"

# The gate's actual subject: Alpine running a test Ubuntu knows is broken.
expect "a baseline title absent from Alpine fails" 1 "Missing baseline skips" \
  "ubu/webkit.titles.txt:$TITLE"

# Run 35972784207's -1: the title is skipped on Alpine, but by the
# capability-gated list rather than the unconditional one.
expect "a baseline title covered by needs-headed passes" 0 "| webkit |" \
  "ubu/webkit.titles.txt:$TITLE" "alp/webkit.needs-headed.titles.txt:$TITLE"

# Counting needs-headed must not stop the gate checking titles at all — a
# different missing title still fails while needs-headed covers another.
expect "an uncovered title still fails beside a covered one" 1 "Missing baseline skips" \
  "ubu/webkit.titles.txt:$TITLE" "alp/webkit.needs-headed.titles.txt:$TITLE" \
  "ubu/webkit.titles.txt:should capture navigation\$"

# needs-headed is a titles-only list; it must not satisfy a files entry.
expect "needs-headed does not cover a files entry" 1 "Missing baseline skips" \
  "ubu/webkit.files.txt:library/video.spec.ts" \
  "alp/webkit.needs-headed.titles.txt:library/video.spec.ts"

# Scoped per browser: webkit's list cannot cover firefox's baseline.
expect "needs-headed does not cross browsers" 1 "Missing baseline skips" \
  "ubu/firefox.titles.txt:$TITLE" "alp/webkit.needs-headed.titles.txt:$TITLE"

echo "check-skip-parity: $((checks - failures))/$checks checks passed"
[ "$failures" -eq 0 ]
