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
#   per (browser, shard, suite) with `passed=` `failed=` `skipped=` `flaky=`
#   fields (written by playwright/alpine-browsers/conformance/run.sh).
#
# Rules:
#   - Sum passes per browser on each side. A flaky test is a pass: PW retried
#     it and it went green, and PW's own exit code says so. Counting only the
#     first-try passes turned one retry on Alpine into a -1 regression (run
#     34652798588, shard 6: `110 passed, 1 flaky` against Ubuntu's 111).
#   - Compare only the SUITES that ran on both sides, and only the browsers
#     that ran on both sides. Same rule at two granularities: a leg absent on
#     one side was not built, and what was never built cannot have regressed.
#     The browser half covers a per-browser dispatch — a firefox-only run
#     would otherwise read as "chromium regressed by 5950" and, once the exit
#     code is honoured, red every such run. The suite half covers webkit's
#     headed leg: we ship a WPE-only artifact, so conformance/run.sh sets
#     HEADED_ENABLED=0 and writes no `headed` row, while Ubuntu's leg reports
#     `suite=headed passed=14`. Run 35972784207 read that as Δ −15 with zero
#     failures on either side. GTK is not coverage we lost, it is coverage we
#     never built; this gate's subject is upstream drift on the legs we run.
#   - FAIL if Alpine < Ubuntu over those shared suites.
#   - Otherwise print the markdown tally and exit 0.
#
# Every suite dropped from a comparison is named in the output. A suite that
# disappears for a BAD reason — the runner stopped emitting it, a leg silently
# died — looks exactly like webkit's headed leg to the sums, so printing which
# suites were dropped is the only thing that separates the two.
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

# `suite<TAB>passed<TAB>failed<TAB>skipped<TAB>flaky`, one line per suite this
# browser reported anywhere under the directory, summed across its shards.
suite_totals() {
  local dir="$1" browser="$2"
  find "$dir" -name stats.txt -print0 2>/dev/null | \
    xargs -0 -r cat 2>/dev/null | \
    awk -v b="$browser" '
      $0 ~ ("browser=" b " ") {
        suite = ""; delete field
        for (i = 1; i <= NF; i++) {
          if (split($i, kv, "=") == 2) {
            if (kv[1] == "suite") suite = kv[2]
            else field[kv[1]] = kv[2]
          }
        }
        if (suite == "") next
        seen[suite] = 1
        passed[suite]  += field["passed"]
        failed[suite]  += field["failed"]
        skipped[suite] += field["skipped"]
        flaky[suite]   += field["flaky"]
      }
      END {
        for (s in seen)
          printf "%s\t%d\t%d\t%d\t%d\n", \
            s, passed[s], failed[s], skipped[s], flaky[s]
      }
    ' | sort
}

echo "## Runtime parity"
echo ""
echo "Alpine conformance pass counts must be **≥** Ubuntu baseline pass counts"
echo "per browser at each PW version. Otherwise Alpine is regressing tests PW"
echo "itself now covers, and \"same-or-better\" is no longer true."
echo ""
echo "Only suites that ran on both sides are compared; any suite left out is"
echo "named under the table."
echo ""
echo "| Browser | Alpine (passed incl. flaky / failed / skipped) | Ubuntu (passed incl. flaky / failed / skipped) | Δ passed | status |"
echo "|---|---|---|---|---|"

rc=0
dropped_notes=()
for b in "${BROWSERS[@]}"; do
  unset alpine_passed alpine_failed alpine_skipped alpine_flaky || true
  unset ubuntu_passed ubuntu_failed ubuntu_skipped ubuntu_flaky || true
  declare -A alpine_passed alpine_failed alpine_skipped alpine_flaky
  declare -A ubuntu_passed ubuntu_failed ubuntu_skipped ubuntu_flaky

  # `${#assoc[@]}` on a declared-but-empty associative array is unbound under
  # `set -u`, so presence is tracked from the rows actually read. The while
  # loop keeps its assignments: process substitution runs it in this shell.
  alpine_suites=""; ubuntu_suites=""
  while IFS=$'\t' read -r suite passed failed skipped flaky; do
    alpine_suites+="$suite"$'\n'
    alpine_passed[$suite]=$passed;   alpine_failed[$suite]=$failed
    alpine_skipped[$suite]=$skipped; alpine_flaky[$suite]=$flaky
  done < <(suite_totals "$ALPINE_DIR" "$b")

  while IFS=$'\t' read -r suite passed failed skipped flaky; do
    ubuntu_suites+="$suite"$'\n'
    ubuntu_passed[$suite]=$passed;   ubuntu_failed[$suite]=$failed
    ubuntu_skipped[$suite]=$skipped; ubuntu_flaky[$suite]=$flaky
  done < <(suite_totals "$UBUNTU_DIR" "$b")

  # Presence, not pass count: a browser that ran and passed nothing is a
  # regression, a browser that never ran is not comparable at all.
  if [ -n "$alpine_suites" ]; then alpine_ran=1; else alpine_ran=0; fi
  if [ -n "$ubuntu_suites" ]; then ubuntu_ran=1; else ubuntu_ran=0; fi

  alpine_pass=0; alpine_fail=0; alpine_skip=0
  ubuntu_pass=0; ubuntu_fail=0; ubuntu_skip=0
  alpine_only=(); ubuntu_only=()
  all_suites=$(printf '%s%s' "$alpine_suites" "$ubuntu_suites" | sort -u)
  for suite in $all_suites; do
    if [ -z "${alpine_passed[$suite]+set}" ]; then ubuntu_only+=("$suite"); continue; fi
    if [ -z "${ubuntu_passed[$suite]+set}" ]; then alpine_only+=("$suite"); continue; fi
    alpine_pass=$(( alpine_pass + alpine_passed[$suite] + alpine_flaky[$suite] ))
    alpine_fail=$(( alpine_fail + alpine_failed[$suite] ))
    alpine_skip=$(( alpine_skip + alpine_skipped[$suite] ))
    ubuntu_pass=$(( ubuntu_pass + ubuntu_passed[$suite] + ubuntu_flaky[$suite] ))
    ubuntu_fail=$(( ubuntu_fail + ubuntu_failed[$suite] ))
    ubuntu_skip=$(( ubuntu_skip + ubuntu_skipped[$suite] ))
  done

  if [ "$alpine_ran" = 0 ] && [ "$ubuntu_ran" = 0 ]; then
    status="— (neither side ran)"
  elif [ "$alpine_ran" = 0 ]; then
    status="— (not built this run)"
  elif [ "$ubuntu_ran" = 0 ]; then
    status="— (no Ubuntu baseline)"
  elif [ "$alpine_pass" -lt "$ubuntu_pass" ]; then
    status="✗ **FAIL**"
    rc=1
  else
    status="✓"
  fi
  printf "| %s | %s / %s / %s | %s / %s / %s | %+d | %s |\n" \
    "$b" "$alpine_pass" "$alpine_fail" "$alpine_skip" \
    "$ubuntu_pass" "$ubuntu_fail" "$ubuntu_skip" \
    "$((alpine_pass - ubuntu_pass))" "$status"

  if [ "$alpine_ran" = 1 ] && [ "$ubuntu_ran" = 1 ]; then
    if [ "${#ubuntu_only[@]}" -gt 0 ]; then
      dropped_notes+=("- \`$b\` — Alpine ran no \`${ubuntu_only[*]}\`, so Ubuntu's is not compared")
    fi
    if [ "${#alpine_only[@]}" -gt 0 ]; then
      dropped_notes+=("- \`$b\` — Ubuntu ran no \`${alpine_only[*]}\`, so Alpine's is not compared")
    fi
  fi
done

if [ "${#dropped_notes[@]}" -gt 0 ]; then
  echo ""
  echo "### Suites left out of the comparison"
  echo ""
  printf '%s\n' "${dropped_notes[@]}"
fi

if [ "$rc" -ne 0 ]; then
  echo ""
  echo "### ✗ Alpine regressed vs Ubuntu"
  echo ""
  echo "One or more browsers show fewer passes on Alpine than on the Ubuntu"
  echo "baseline, on a suite both sides ran. Either widen Alpine coverage or"
  echo "document the regression as an upstream gap in the corresponding"
  echo "skip-list. See per-shard logs" >&2
  echo "in the artifacts for the specific failing tests." >&2
fi

exit "$rc"
