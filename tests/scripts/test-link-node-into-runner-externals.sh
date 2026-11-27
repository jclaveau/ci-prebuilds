#!/usr/bin/env bash
# Unit test for node/link-node-into-runner-externals.sh, which points the path a GHA container
# job's JS actions exec (`/__e/node<major>_alpine/bin/node`) at the image's own node.
#
# The node under test is a shell script on a scratch PATH and the externals directory is a temp
# dir, so nothing touches a real node or a real /__e. No network, no docker. The runtime half —
# that a real JS action execs this symlink — is asserted by test-and-publish's test-node-usage.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINK="$HERE/../../node/link-node-into-runner-externals.sh"
[[ -x "$LINK" ]] || { echo "FAIL: $LINK not found or not executable" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/image-bin"
printf '#!/bin/sh\necho 26.13.0\n' > "$WORK/image-bin/node"
chmod 755 "$WORK/image-bin/node"
export PATH="$WORK/image-bin:$PATH"

run_link() { # prints stdout+stderr, echoes the exit code on the last line
  local rc=0
  "$LINK" "$@" 2>&1 || rc=$?
  echo "rc=$rc"
}

failures=0
expect_output() { # <label> <expected substring> <actual>
  if [[ "$3" == *"$2"* ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1 — expected to contain: $2" >&2
    echo "--- got ---" >&2
    echo "$3" >&2
    failures=$((failures + 1))
  fi
}

echo "=== no argument names the argument it needs ==="
output=$(run_link)
expect_output "no argument refuses" \
  "link-node-into-runner-externals needs the runner externals node directory as its argument, e.g. /__e/node24_alpine" \
  "$output"
expect_output "no argument exits 1" "rc=1" "$output"

echo "=== a relative path refuses, naming it ==="
output=$(run_link "node24_alpine")
expect_output "relative path refuses" \
  "node24_alpine is relative, and the runner reads this path from the job container's root, so it must be absolute" \
  "$output"
expect_output "relative path exits 1" "rc=1" "$output"

echo "=== a directory no runtime resolves refuses, naming the shape ==="
for bad_dir in "$WORK/__e/node24" "$WORK/__e/node_alpine" "$WORK/__e/node24_alpine_sudoer"; do
  output=$(run_link "$bad_dir")
  expect_output "$bad_dir refuses" \
    "$bad_dir does not end in node<major>_alpine, so no runtime the runner resolves would exec it" \
    "$output"
  expect_output "$bad_dir exits 1" "rc=1" "$output"
done

echo "=== no node in the image refuses rather than linking a dangling path ==="
output=$(PATH="/nonexistent-for-this-test" run_link "$WORK/__e/node24_alpine")
expect_output "missing node refuses" \
  "node is missing from this image, so there is nothing to link into $WORK/__e/node24_alpine" \
  "$output"
expect_output "missing node exits 1" "rc=1" "$output"
[[ -e "$WORK/__e/node24_alpine/bin/node" ]] \
  && { echo "FAIL: it created the link it refused to make" >&2; failures=$((failures + 1)); }

echo "=== the happy path links the image's node and names the version it reached ==="
output=$(run_link "$WORK/__e/node24_alpine")
expect_output "happy path reports the link" \
  "node 26.13.0 linked at $WORK/__e/node24_alpine/bin/node -> $WORK/image-bin/node" \
  "$output"
expect_output "happy path exits 0" "rc=0" "$output"
linked_target=$(readlink "$WORK/__e/node24_alpine/bin/node")
[[ "$linked_target" == "$WORK/image-bin/node" ]] \
  || { echo "FAIL: the symlink points at $linked_target" >&2; failures=$((failures + 1)); }

echo "=== a second run replaces an older link instead of failing on it ==="
mkdir -p "$WORK/other-bin"
printf '#!/bin/sh\necho 26.13.0\n' > "$WORK/other-bin/node"
chmod 755 "$WORK/other-bin/node"
output=$(PATH="$WORK/other-bin:$PATH" run_link "$WORK/__e/node24_alpine")
expect_output "relink exits 0" "rc=0" "$output"
linked_target=$(readlink "$WORK/__e/node24_alpine/bin/node")
[[ "$linked_target" == "$WORK/other-bin/node" ]] \
  || { echo "FAIL: the relink still points at $linked_target" >&2; failures=$((failures + 1)); }

echo "=== a node whose version differs from the linked one refuses ==="
mkdir -p "$WORK/drifting-bin"
cat > "$WORK/drifting-bin/node" <<'FAKE'
#!/bin/sh
# Prints a different version on every call, as a node replaced between the two reads would.
counter_file="${FAKE_NODE_COUNTER:?}"
count=$(cat "$counter_file")
echo $((count + 1)) > "$counter_file"
echo "26.13.$count"
FAKE
chmod 755 "$WORK/drifting-bin/node"
echo 0 > "$WORK/node-counter"
output=$(FAKE_NODE_COUNTER="$WORK/node-counter" PATH="$WORK/drifting-bin:$PATH" \
  run_link "$WORK/__e/node26_alpine")
expect_output "version drift refuses" \
  "$WORK/__e/node26_alpine/bin/node runs node 26.13.1, not the image's 26.13.0" \
  "$output"
expect_output "version drift exits 1" "rc=1" "$output"

if (( failures > 0 )); then
  echo "$failures assertion(s) failed" >&2
  exit 1
fi
echo "all assertions passed"
