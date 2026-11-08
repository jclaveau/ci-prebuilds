#!/usr/bin/env bash
# Unit test for node/record-image-tool.sh + node/assert-prebuilt-tools-in-use.sh, the pair
# that answers "did a step re-download a tool this image already carries?".
#
# Both read CI_PREBUILDS_MANIFEST instead of /etc/ci-prebuilds/prebuilt-tools.tsv here, and
# the tool under test is a shell script on a scratch PATH, so nothing touches a real node.
# No network, no docker.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RECORD="$HERE/../../node/record-image-tool.sh"
ASSERT="$HERE/../../node/assert-prebuilt-tools-in-use.sh"

for script in "$RECORD" "$ASSERT"; do
  [[ -x "$script" ]] || { echo "FAIL: $script not found or not executable" >&2; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export CI_PREBUILDS_MANIFEST="$WORK/etc/prebuilt-tools.tsv"

# The baked tool: an executable whose --version the scripts read like node's or pnpm's.
mkdir -p "$WORK/image-bin" "$WORK/step-bin"
write_faketool() { # <dir> <version>
  printf '#!/bin/sh\necho v%s\n' "$2" > "$1/faketool"
  chmod 755 "$1/faketool"
}
write_faketool "$WORK/image-bin" 1.2.3
export PATH="$WORK/image-bin:$PATH"

run_assert() { # prints stdout+stderr, echoes the exit code on the last line
  local rc=0
  # 2>&1 because without GITHUB_ACTIONS the findings go to stderr, not the log annotations.
  "$ASSERT" "$@" 2>&1 || rc=$?
  echo "rc=$rc"
}

echo "=== record writes one row naming the resolved path, version, size and mtime ==="
"$RECORD" faketool >/dev/null
ROW=$(cat "$CI_PREBUILDS_MANIFEST")
EXPECTED_HEAD=$(printf 'faketool\t%s/image-bin/faketool\t1.2.3' "$WORK")
[[ "$ROW" == "$EXPECTED_HEAD"* ]] || { echo "FAIL: row is $ROW" >&2; exit 1; }
[[ $(awk -F'\t' 'END { print NF }' "$CI_PREBUILDS_MANIFEST") == 5 ]] \
  || { echo "FAIL: row is not 5 fields: $ROW" >&2; exit 1; }
echo "PASS: $ROW"

echo "=== recording the same tool twice replaces its row, never appends a second ==="
"$RECORD" faketool >/dev/null
[[ $(wc -l < "$CI_PREBUILDS_MANIFEST") -eq 1 ]] \
  || { echo "FAIL: $(cat "$CI_PREBUILDS_MANIFEST")" >&2; exit 1; }
echo "PASS: still one row"

echo "=== untouched tool: no finding, exit 0 in error mode ==="
OUT=$(run_assert --severity error)
grep -q '1 prebuilt tools checked, all still the image.s' <<<"$OUT" \
  || { echo "FAIL: $OUT" >&2; exit 1; }
grep -qx 'rc=0' <<<"$OUT" || { echo "FAIL: $OUT" >&2; exit 1; }
echo "PASS"

echo "=== a step earlier on PATH: REPLACED, exit 1 in error mode, 0 in warning mode ==="
write_faketool "$WORK/step-bin" 9.9.9
SHADOWED_PATH="$WORK/step-bin:$PATH"
OUT=$(PATH="$SHADOWED_PATH" run_assert --severity error)
grep -q 'REPLACED' <<<"$OUT" || { echo "FAIL: $OUT" >&2; exit 1; }
grep -q '9.9.9' <<<"$OUT" || { echo "FAIL: live version missing: $OUT" >&2; exit 1; }
grep -qx 'rc=1' <<<"$OUT" || { echo "FAIL: $OUT" >&2; exit 1; }
OUT=$(PATH="$SHADOWED_PATH" run_assert --severity warning)
grep -q 'severity=warning, not failing the job' <<<"$OUT" \
  || { echo "FAIL: $OUT" >&2; exit 1; }
grep -qx 'rc=0' <<<"$OUT" || { echo "FAIL: $OUT" >&2; exit 1; }
echo "PASS"

echo "=== a snapshot proving the image's path was still live at prepare names the job ==="
SNAPSHOT="$WORK/snapshot.tsv"
"$ASSERT" --write-snapshot "$SNAPSHOT" >/dev/null
EXPECTED_SNAPSHOT=$(printf 'faketool\t%s/image-bin/faketool' "$WORK")
[[ "$(cat "$SNAPSHOT")" == "$EXPECTED_SNAPSHOT" ]] \
  || { echo "FAIL: snapshot is $(cat "$SNAPSHOT")" >&2; exit 1; }
OUT=$(PATH="$SHADOWED_PATH" GITHUB_ACTIONS=true run_assert --severity warning --snapshot "$SNAPSHOT")
grep -q "::warning::faketool was the image's $WORK/image-bin/faketool at prepare and resolves to $WORK/step-bin/faketool by the end of the job — a step installed its own" <<<"$OUT" \
  || { echo "FAIL: $OUT" >&2; exit 1; }
echo "PASS"

echo "=== the baked path overwritten in place: REPLACED on the size+mtime fingerprint ==="
write_faketool "$WORK/image-bin" 4.5.6-rewritten
OUT=$(run_assert --severity error)
grep -q 'is no longer the file the image baked' <<<"$OUT" || { echo "FAIL: $OUT" >&2; exit 1; }
grep -qx 'rc=1' <<<"$OUT" || { echo "FAIL: $OUT" >&2; exit 1; }
echo "PASS"

echo "=== the tool gone from PATH entirely: MISSING ==="
OUT=$(PATH=/usr/bin:/bin run_assert --severity error)
grep -q 'MISSING' <<<"$OUT" || { echo "FAIL: $OUT" >&2; exit 1; }
grep -q 'nothing answers to the name any more' <<<"$OUT" || { echo "FAIL: $OUT" >&2; exit 1; }
grep -qx 'rc=1' <<<"$OUT" || { echo "FAIL: $OUT" >&2; exit 1; }
echo "PASS"

echo "=== severity governs findings, never the ability to run ==="
for arm in \
  "missing manifest:CI_PREBUILDS_MANIFEST=$WORK/absent.tsv:--severity warning" \
  "bad severity value:CI_PREBUILDS_MANIFEST=$CI_PREBUILDS_MANIFEST:--severity loud" \
  "unknown argument:CI_PREBUILDS_MANIFEST=$CI_PREBUILDS_MANIFEST:--allow faketool"
do
  label=${arm%%:*}; rest=${arm#*:}; env_pair=${rest%%:*}; args=${rest#*:}
  rc=0
  # shellcheck disable=SC2086
  env "$env_pair" "$ASSERT" $args >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 1 ]] || { echo "FAIL: $label exited $rc, expected 1" >&2; exit 1; }
  echo "PASS: $label exits 1 even in warning mode"
done

printf 'faketool\tonly-two\tfields\n' > "$WORK/etc/malformed.tsv"
rc=0
CI_PREBUILDS_MANIFEST="$WORK/etc/malformed.tsv" "$ASSERT" --severity warning >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] || { echo "FAIL: malformed manifest exited $rc, expected 1" >&2; exit 1; }
echo "PASS: a row that is not 5 fields exits 1 even in warning mode"

echo "=== record refuses a name that is not on PATH ==="
rc=0
PATH=/usr/bin:/bin "$RECORD" faketool >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] || { echo "FAIL: record exited $rc, expected 1" >&2; exit 1; }
echo "PASS"

echo "ALL PASS"
