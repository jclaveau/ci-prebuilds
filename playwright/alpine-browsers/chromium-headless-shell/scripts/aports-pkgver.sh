#!/usr/bin/env bash
# The one place that decides whether an aports commit's chromium matches the
# one Playwright pins. SOURCED, never executed.
#
# Three callers ask this question and they used to answer it three times:
#   - apply-and-build.sh, inside the producer build
#   - tests/aports/test-versions-env-consistency.sh, at PR time
#   - .github/workflows/auto-resolve-aports.yml, on Renovate's bump
#
# The last two said in their own comments that they mirrored the first, and
# both still did strict equality long after it had been relaxed. That is not a
# hypothetical: it made the 1.62.1 bump structurally red — no aports SHA could
# satisfy them — and cost a full round of CI to diagnose. Hence one rule, one
# file, three callers.
#
# The rule: compare the first three dot-segments, not the whole version. Alpine
# packages only some patch releases (aports went 150.0.7871.181 straight to
# 151.0.7922.71) while Playwright pins 151.0.7922.34, so exact equality is
# unsatisfiable by ANY aports commit and no published Playwright aligns either.
# Relaxing it is safe because this pin only selects which musl patches get
# applied; the version actually shipped is asserted against the built binary.

chromium_branch_of() {
  echo "$1" | awk -F. '{print $1"."$2"."$3}'
}

# chromium_pkgver_status <aports_pkgver> <pw_chs_ver>
#
# Returns the DECISION and leaves the messaging to the caller, because the
# three of them speak differently — GitHub `::warning::` annotations in two,
# plain stderr in the test.
#
#   0  exact match
#   1  same branch, patch-level drift  (expected, and fine)
#   2  different branch                (the patches were authored elsewhere)
#
# Under `set -e` a non-zero return aborts the script, so callers MUST consume
# this in an `if`/`case` or via `|| status=$?` — never as a bare statement.
chromium_pkgver_status() {
  local aports_pkgver="$1" pw_chs_ver="$2"
  if [ "$aports_pkgver" = "$pw_chs_ver" ]; then
    return 0
  fi
  if [ "$(chromium_branch_of "$aports_pkgver")" \
     = "$(chromium_branch_of "$pw_chs_ver")" ]; then
    return 1
  fi
  return 2
}
