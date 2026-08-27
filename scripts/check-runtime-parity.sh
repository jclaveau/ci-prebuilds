#!/usr/bin/env bash
# Assert Alpine conformance pass count ≥ Ubuntu conformance pass count per
# browser at runtime. The skip-list parity gate covers the STATIC surface
# (Alpine skip-list ⊇ Ubuntu skip-list). This gate covers the DYNAMIC one:
# if PW ships a new version where Ubuntu suddenly passes 20 more tests
# (thanks to an upstream fix) but Alpine still fails them, we want CI to
# red before we ship a "same-or-better" claim we can't back.
#
# Input: two directories of shard-report artifacts, each containing many
#   `report-<browser>-<shard>/stats.txt` files. `stats.txt` has one line
#   per (browser, shard, suite) with `passed=` `failed=` `skipped=` fields
#   (written by playwright/alpine-browsers/conformance/run.sh).
#
# Rules:
#   - Sum passes per browser on each side.
#   - FAIL if Alpine < Ubuntu on any browser that RAN on both sides.
#   - A browser with no shards on a side did not run — the producer builds
#     per-browser and the Ubuntu control leg runs on its own schedule, so a
#     firefox-only dispatch would otherwise read as "chromium regressed by
#     5950" and, once the exit code is honoured, red every such run.
#   - Otherwise print the markdown tally and exit 0.
#
# The caller must not swallow the exit code. `script | tee -a $GITHUB_STEP_SUMMARY`
# takes tee's status unless the step sets `pipefail`, which is how run
# 32941298683 printed "✗ FAIL" and concluded green.
#
# Usage: check-runtime-parity.sh <alpine_dir> <ubuntu_dir>

set -eu

ALPINE_DIR="${1:?usage: check-runtime-parity.sh <alpine_dir> <ubuntu_dir>}"
UBUNTU_DIR="${2:?usage: check-runtime-parity.sh <alpine_dir> <ubuntu_dir>}"

BROWSERS=(chromium firefox webkit)

# Presence, not pass count: a browser that ran and passed nothing is a
# regression, a browser that never ran is not comparable at all.
has_shards() {
  local dir="$1" browser="$2"
  find "$dir" -name stats.txt -print0 2>/dev/null | \
    xargs -0 -r cat 2>/dev/null | \
    grep -q "browser=$browser "
}

sum_field() {
  local dir="$1" browser="$2" field="$3"
  find "$dir" -name stats.txt -print0 2>/dev/null | \
    xargs -0 -r cat | \
    awk -v b="$browser" -v f="$field" '
      $0 ~ ("browser="b" ") {
        for (i=1;i<=NF;i++) {
          if (split($i,a,"=")==2 && a[1]==f) { sum+=a[2] }
        }
      }
      END { print sum+0 }
    '
}

echo "## Runtime parity"
echo ""
echo "Alpine conformance pass counts must be **≥** Ubuntu baseline pass counts"
echo "per browser at each PW version. Otherwise Alpine is regressing tests PW"
echo "itself now covers, and \"same-or-better\" is no longer true."
echo ""
echo "| Browser | Alpine (passed / failed / skipped) | Ubuntu (passed / failed / skipped) | Δ passed | status |"
echo "|---|---|---|---|---|"

rc=0
for b in "${BROWSERS[@]}"; do
  a_pass=$(sum_field "$ALPINE_DIR" "$b" passed)
  a_fail=$(sum_field "$ALPINE_DIR" "$b" failed)
  a_skip=$(sum_field "$ALPINE_DIR" "$b" skipped)
  u_pass=$(sum_field "$UBUNTU_DIR" "$b" passed)
  u_fail=$(sum_field "$UBUNTU_DIR" "$b" failed)
  u_skip=$(sum_field "$UBUNTU_DIR" "$b" skipped)
  delta=$((a_pass - u_pass))
  a_ran=0; has_shards "$ALPINE_DIR" "$b" && a_ran=1
  u_ran=0; has_shards "$UBUNTU_DIR" "$b" && u_ran=1
  if [ "$a_ran" = 0 ] && [ "$u_ran" = 0 ]; then
    status="— (neither side ran)"
  elif [ "$a_ran" = 0 ]; then
    status="— (not built this run)"
  elif [ "$u_ran" = 0 ]; then
    status="— (no Ubuntu baseline)"
  elif [ "$a_pass" -lt "$u_pass" ]; then
    status="✗ **FAIL**"
    rc=1
  else
    status="✓"
  fi
  printf "| %s | %s / %s / %s | %s / %s / %s | %+d | %s |\n" \
    "$b" "$a_pass" "$a_fail" "$a_skip" "$u_pass" "$u_fail" "$u_skip" "$delta" "$status"
done

if [ "$rc" -ne 0 ]; then
  echo ""
  echo "### ✗ Alpine regressed vs Ubuntu"
  echo ""
  echo "One or more browsers show fewer passes on Alpine than on the Ubuntu"
  echo "baseline. Either widen Alpine coverage or document the regression as"
  echo "an upstream gap in the corresponding skip-list. See per-shard logs" >&2
  echo "in the artifacts for the specific failing tests." >&2
fi

exit "$rc"
