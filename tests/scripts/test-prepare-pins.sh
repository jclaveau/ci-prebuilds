#!/usr/bin/env bash
# Unit test for the three opt-in inputs of .github/actions/prepare/prepare.js:
# node-version-file, compare-pnpm-pin and pnpm-store.
#
# The action runs on the real node, by absolute path, while `node` and `pnpm` on its PATH
# are shims printing the version a row sets (FAKE_NODE_VERSION, FAKE_PNPM_VERSION; unset
# pnpm = not installed). A scratch workspace holds the .nvmrc and package.json under test.
# The socket join is pointed at a socket that does not exist, so it does nothing. No
# network, no docker.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREPARE="$HERE/../../.github/actions/prepare/prepare.js"
[[ -f "$PREPARE" ]] || { echo "FAIL: $PREPARE not found" >&2; exit 1; }
REAL_NODE=$(command -v node) || { echo "FAIL: node is needed to run the action under test" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/workspace"
cat > "$WORK/bin/node" <<'SHIM'
#!/bin/sh
echo "v$FAKE_NODE_VERSION"
SHIM
cat > "$WORK/bin/pnpm" <<'SHIM'
#!/bin/sh
[ -n "${FAKE_PNPM_VERSION:-}" ] || exit 127
echo "$FAKE_PNPM_VERSION"
SHIM
chmod 755 "$WORK/bin/node" "$WORK/bin/pnpm"

export PATH="$WORK/bin:$PATH"
export GITHUB_WORKSPACE="$WORK/workspace"
export GITHUB_ENV="$WORK/github-env"
export GITHUB_OUTPUT="$WORK/github-output"
export GITHUB_STATE="$WORK/github-state"
export CI_PREBUILDS_DOCKER_SOCKET="$WORK/there-is-no-socket-here.sock"
export DOCKER_MODE=dood
export HOST_ADDRESS=host.docker.internal
export FAKE_NODE_VERSION=24.22.1

run_prepare() { # <env assignments...>: the inputs of one row
  : > "$GITHUB_ENV"
  : > "$GITHUB_OUTPUT"
  (cd "$GITHUB_WORKSPACE" && env "$@" "$REAL_NODE" "$PREPARE" 2>&1)
}

fail() { echo "FAIL: $1" >&2; exit 1; }

expect_line() { # <output> <exact line>
  printf '%s\n' "$1" | grep -qxF -- "$2" || fail "no line ${2@Q}; output was: $1"
}

expect_rc() { # <expected rc> <actual rc> <output>
  [[ "$1" == "$2" ]] || fail "rc $2, expected $1; output was: $3"
}

echo "=== .nvmrc v24.22.0, image node 24.22.1: major.minor matches ==="
echo v24.22.0 > "$GITHUB_WORKSPACE/.nvmrc"
rc=0; out=$(run_prepare INPUT_NODE-VERSION-FILE=.nvmrc) || rc=$?
expect_rc 0 "$rc" "$out"
expect_line "$out" "node 24.22.1 matches .nvmrc 24.22"

echo "=== .nvmrc 24.11.0, image node 24.22.1: mismatch fails the step ==="
echo 24.11.0 > "$GITHUB_WORKSPACE/.nvmrc"
rc=0; out=$(run_prepare INPUT_NODE-VERSION-FILE=.nvmrc) || rc=$?
expect_rc 1 "$rc" "$out"
expect_line "$out" "::error::node mismatch: .nvmrc=24.11 image=24.22 — bump the image tag"

echo "=== .nvmrc 24, image node 24.22.1: compared at the file's precision ==="
echo 24 > "$GITHUB_WORKSPACE/.nvmrc"
rc=0; out=$(run_prepare INPUT_NODE-VERSION-FILE=.nvmrc) || rc=$?
expect_rc 0 "$rc" "$out"
expect_line "$out" "node 24.22.1 matches .nvmrc 24"

echo "=== .nvmrc lts/*: refused, no version to hold the image to ==="
echo 'lts/*' > "$GITHUB_WORKSPACE/.nvmrc"
rc=0; out=$(run_prepare INPUT_NODE-VERSION-FILE=.nvmrc) || rc=$?
expect_rc 1 "$rc" "$out"
expect_line "$out" '::error::.nvmrc pins "lts/*": only a numeric version can be compared with the image node'

echo "=== no .nvmrc in the workspace (prepare before checkout): refused ==="
rm "$GITHUB_WORKSPACE/.nvmrc"
rc=0; out=$(run_prepare INPUT_NODE-VERSION-FILE=.nvmrc) || rc=$?
expect_rc 1 "$rc" "$out"
expect_line "$out" '::error::node-version-file ".nvmrc" could not be read ("ENOENT"): run prepare after actions/checkout'

echo "=== DOCKER_MODE=vm: no image node, the check is setup-node's ==="
rc=0; out=$(run_prepare DOCKER_MODE=vm INPUT_NODE-VERSION-FILE=.nvmrc) || rc=$?
expect_rc 0 "$rc" "$out"
expect_line "$out" "DOCKER_MODE=vm: no image node to compare with .nvmrc, setup-node reads it"

echo "=== packageManager pnpm@11.2.0, image pnpm 11.2.0: matches ==="
echo '{ "packageManager": "pnpm@11.2.0" }' > "$GITHUB_WORKSPACE/package.json"
rc=0; out=$(FAKE_PNPM_VERSION=11.2.0 run_prepare INPUT_COMPARE-PNPM-PIN=true) || rc=$?
expect_rc 0 "$rc" "$out"
expect_line "$out" "packageManager pins pnpm 11.2.0, image ships 11.2.0 (pnpm-matches-pin=true)"
[[ "$(cat "$GITHUB_OUTPUT")" == "pnpm-matches-pin=true" ]] || fail "GITHUB_OUTPUT was: $(cat "$GITHUB_OUTPUT")"

echo "=== a corepack hash after the version: the version alone is compared ==="
echo '{ "packageManager": "pnpm@11.2.0+sha512.abc" }' > "$GITHUB_WORKSPACE/package.json"
rc=0; out=$(FAKE_PNPM_VERSION=11.2.0 run_prepare INPUT_COMPARE-PNPM-PIN=true) || rc=$?
expect_rc 0 "$rc" "$out"
[[ "$(cat "$GITHUB_OUTPUT")" == "pnpm-matches-pin=true" ]] || fail "GITHUB_OUTPUT was: $(cat "$GITHUB_OUTPUT")"

echo "=== image pnpm 11.1.0: no match, the step stays green ==="
rc=0; out=$(FAKE_PNPM_VERSION=11.1.0 run_prepare INPUT_COMPARE-PNPM-PIN=true) || rc=$?
expect_rc 0 "$rc" "$out"
[[ "$(cat "$GITHUB_OUTPUT")" == "pnpm-matches-pin=false" ]] || fail "GITHUB_OUTPUT was: $(cat "$GITHUB_OUTPUT")"

echo "=== no pnpm on PATH: no match ==="
rc=0; out=$(run_prepare INPUT_COMPARE-PNPM-PIN=true) || rc=$?
expect_rc 0 "$rc" "$out"
expect_line "$out" "packageManager pins pnpm 11.2.0, image ships none (pnpm-matches-pin=false)"

echo "=== no packageManager pin: refused ==="
echo '{ "name": "app" }' > "$GITHUB_WORKSPACE/package.json"
rc=0; out=$(FAKE_PNPM_VERSION=11.2.0 run_prepare INPUT_COMPARE-PNPM-PIN=true) || rc=$?
expect_rc 1 "$rc" "$out"
expect_line "$out" "::error::package.json declares no pnpm packageManager pin (packageManager=undefined)"

echo "=== pnpm-store: true exports the three variables of the pnpm-store action ==="
rc=0; out=$(run_prepare INPUT_PNPM-STORE=true) || rc=$?
expect_rc 0 "$rc" "$out"
grep -qxF "pnpm_config_store_dir=$GITHUB_WORKSPACE/.pnpm-store" "$GITHUB_ENV" || fail "GITHUB_ENV was: $(cat "$GITHUB_ENV")"
grep -qxF "STORE_PATH=.pnpm-store" "$GITHUB_ENV" || fail "GITHUB_ENV was: $(cat "$GITHUB_ENV")"
grep -qE "^LIBC_TAG=-(musl|glibc)$" "$GITHUB_ENV" || fail "GITHUB_ENV was: $(cat "$GITHUB_ENV")"

echo "=== pnpm-store refusing a path: the step fails ==="
rc=0; out=$(run_prepare INPUT_PNPM-STORE=true pnpm_config_store_dir=relative/store) || rc=$?
expect_rc 1 "$rc" "$out"
expect_line "$out" "::error::pnpm_config_store_dir=relative/store is refused: it is not an absolute path"
expect_line "$out" '::error::the pnpm store could not be resolved (1)'

echo "=== none of the inputs: nothing is exported but the two defaults, no output ==="
rc=0; out=$(run_prepare) || rc=$?
expect_rc 0 "$rc" "$out"
[[ "$(cat "$GITHUB_ENV")" == $'DOCKER_MODE=dood\nHOST_ADDRESS=host.docker.internal' ]] \
  || fail "GITHUB_ENV was: $(cat "$GITHUB_ENV")"
[[ -s "$GITHUB_OUTPUT" ]] && fail "GITHUB_OUTPUT was: $(cat "$GITHUB_OUTPUT")"

echo "=== a boolean input that is neither true nor false: refused ==="
rc=0; out=$(run_prepare INPUT_PNPM-STORE=yes) || rc=$?
expect_rc 1 "$rc" "$out"
expect_line "$out" '::error::pnpm-store is true or false, got "yes"'

echo
echo "PASS: all 15 rows"
