#!/usr/bin/env bash
# Unit test for the shared chromium pkgver rule.
#
# Exists because the rule previously lived in three files and two of them
# drifted to a stricter version than the one that actually gates the build,
# which made the 1.62.1 bump unsatisfiable. A test on the shared copy is what
# stops that recurring silently.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/playwright/alpine-browsers/chromium-headless-shell/scripts/aports-pkgver.sh"

failures=0
checks=0

expect_status() {
  local aports="$1" pinned="$2" want="$3" label="$4"
  local got=0
  chromium_pkgver_status "$aports" "$pinned" || got=$?
  checks=$((checks + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL: $label — $aports vs $pinned gave $got, wanted $want" >&2
    failures=$((failures + 1))
  fi
}

# 0 = exact, 1 = same branch with patch drift, 2 = different branch.
expect_status 151.0.7922.34  151.0.7922.34  0 "exact match"
expect_status 151.0.7922.137 151.0.7922.34  1 "aports ahead within the branch"
expect_status 151.0.7922.34  151.0.7922.137 1 "aports behind within the branch"
# The real pair that broke: aports never packaged .34, and this must not fail.
expect_status 151.0.7922.71  151.0.7922.34  1 "the 1.62.1 pair"
expect_status 148.0.7778.96  151.0.7922.34  2 "different build number"
expect_status 150.0.7871.181 151.0.7922.71  2 "the jump Alpine actually made"
expect_status 152.0.7922.34  151.0.7922.34  2 "different major"
expect_status 151.1.7922.34  151.0.7922.34  2 "different minor"

# The segment count is load-bearing: a 3-segment version must not be read as a
# branch prefix of a 4-segment one.
expect_status 151.0.7922     151.0.7922.34  1 "three-segment aports version"

if [ "$failures" -ne 0 ]; then
  echo "$failures/$checks cases failed" >&2
  exit 1
fi
echo "PASS: chromium_pkgver_status — $checks cases"
