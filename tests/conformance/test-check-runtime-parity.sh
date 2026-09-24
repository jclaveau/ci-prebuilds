#!/usr/bin/env bash
# Unit test for the Alpine-vs-Ubuntu runtime parity gate.
#
# Exists because the gate was inert twice over: the workflow step piped it
# into `tee` without `pipefail` so its exit code never reached CI, and it
# read "this browser was not built in this run" as "this browser regressed
# by every test Ubuntu passes". Run 32941298683 printed `✗ FAIL` for
# chromium and concluded success. Both halves are asserted here — including
# that a real regression still fails, so the fix for the second cannot
# silently neutralise the first.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
GATE="$ROOT/scripts/check-runtime-parity.sh"

failures=0
checks=0
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# One suite's worth of stats.txt, in the format conformance/run.sh writes.
# Appends, so several suites can accumulate under one browser.
seed() {
  local dir="$1" browser="$2" passed="$3" flaky="${4:-0}" suite="${5:-library}"
  mkdir -p "$dir/report-$browser-1"
  printf 'browser=%s shard=1 suite=%s passed=%s failed=0 skipped=0 flaky=%s\n' \
    "$browser" "$suite" "$passed" "$flaky" >> "$dir/report-$browser-1/stats.txt"
}

# $1 label, $2 expected rc, $3 expected status substring, rest: seed specs
# as `side:browser:passed[:flaky[:suite]]` where side is alp or ubu and suite
# defaults to library.
expect() {
  local label="$1" want_rc="$2" want_text="$3"; shift 3
  local case_dir="$workdir/$checks"
  mkdir -p "$case_dir/alp" "$case_dir/ubu"
  local spec side browser passed flaky suite
  for spec in "$@"; do
    IFS=: read -r side browser passed flaky suite <<< "$spec"
    seed "$case_dir/$side" "$browser" "$passed" "${flaky:-0}" "${suite:-library}"
  done

  local out got=0
  out=$("$GATE" "$case_dir/alp" "$case_dir/ubu" 2>&1) || got=$?
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

# The case that shipped green: chromium has a Ubuntu baseline and was not
# built on the Alpine side. Not comparable, so not a failure.
expect "browser absent from the Alpine side" 0 "not built this run" \
  ubu:chromium:5950 alp:firefox:5758 ubu:firefox:5000

# The gate's actual subject — fewer Alpine passes than Ubuntu on a browser
# both sides ran.
expect "genuine regression still fails" 1 "FAIL" \
  alp:firefox:4000 ubu:firefox:5000

# Ran and passed nothing is a regression, not "absent": the shard file
# exists, so the browser was exercised.
expect "zero passes with shards present is a regression" 1 "FAIL" \
  alp:firefox:0 ubu:firefox:5000

expect "equal counts pass" 0 "| firefox |" \
  alp:firefox:5000 ubu:firefox:5000

expect "more Alpine passes pass" 0 "| firefox |" \
  alp:firefox:5758 ubu:firefox:5000

expect "no Ubuntu baseline is not a verdict" 0 "no Ubuntu baseline" \
  alp:webkit:100

# A retry that went green is a pass. Run 34652798588 read shard 6's
# `110 passed, 1 flaky` as one fewer than Ubuntu's 111.
expect "a flaky pass on Alpine is not a regression" 0 "| chromium | 111 /" \
  alp:chromium:110:1 ubu:chromium:111

# ...and symmetrically on the baseline, so a flaky Ubuntu run cannot hide a
# genuine Alpine shortfall.
expect "a flaky pass on Ubuntu still counts against Alpine" 1 "FAIL" \
  alp:chromium:110 ubu:chromium:110:1

# Run 35972784207: Ubuntu's webkit reports `suite=headed passed=14`, Alpine's
# WPE-only artifact reports no headed row at all, and the gate read the whole
# leg as a -14 regression. Coverage never built is not coverage lost.
expect "a suite only Ubuntu ran is not compared" 0 "Alpine ran no \`headed\`" \
  alp:webkit:100 ubu:webkit:100 ubu:webkit:14:0:headed

# ...and symmetrically, so the rule reads the same from either side.
expect "a suite only Alpine ran is not compared" 0 "Ubuntu ran no \`headed\`" \
  alp:webkit:100 alp:webkit:14:0:headed ubu:webkit:100

# The exclusion must not become a hiding place: a shortfall inside a suite
# both sides ran still fails even while another suite is being dropped.
expect "a regression inside a shared suite survives a dropped suite" 1 "FAIL" \
  alp:webkit:99 ubu:webkit:100 ubu:webkit:14:0:headed

# A dropped suite cannot pay for one either — Alpine's surplus there must not
# offset a shortfall in the suite that is actually compared.
expect "a dropped suite cannot offset a shared-suite shortfall" 1 "FAIL" \
  alp:webkit:99 alp:webkit:500:0:headed ubu:webkit:100

echo "check-runtime-parity: $((checks - failures))/$checks checks passed"
[ "$failures" -eq 0 ]
