#!/usr/bin/env bash
# The 11 rows of .github/actions/pnpm-store/pnpm-store.sh: the default store, an override
# inside the workspace, an override outside it (what the act runners bind), the 5 refused
# shapes, the two libc arms, and a job with no GITHUB_ENV to write to.
# GITHUB_WORKSPACE and GITHUB_ENV are a scratch dir and a scratch file, and the musl
# loader is a file the test creates, so no row needs a runner, a container or a real
# pnpm.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ACTION="$HERE/../../.github/actions/pnpm-store/pnpm-store.sh"
[[ -f "$ACTION" ]] || { echo "FAIL: $ACTION not found" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export GITHUB_WORKSPACE="$WORK/workspace"
mkdir -p "$GITHUB_WORKSPACE"
export GITHUB_ENV="$WORK/github-env"

fail() { echo "FAIL: $1" >&2; exit 1; }

run_action() { # reads pnpm_config_store_dir / CI_PREBUILDS_MUSL_LOADER_GLOB from the env
  : > "$GITHUB_ENV"
  bash "$ACTION" 2>&1
}

env_value() { # <name>
  sed -n "s/^$1=//p" "$GITHUB_ENV"
}

echo "=== no override: the store is .pnpm-store, kept under a path cache can tar ==="
unset pnpm_config_store_dir
out=$(run_action)
[[ "$(env_value pnpm_config_store_dir)" == "$GITHUB_WORKSPACE/.pnpm-store" ]] \
  || fail "pnpm got $(env_value pnpm_config_store_dir), not $GITHUB_WORKSPACE/.pnpm-store"
[[ "$(env_value STORE_PATH)" == ".pnpm-store" ]] \
  || fail "STORE_PATH is $(env_value STORE_PATH), not the workspace-relative .pnpm-store"
echo "$out" | grep -q "STORE_PATH=.pnpm-store" \
  || fail "the step logged no STORE_PATH; output was: $out"

echo "=== a glibc box: LIBC_TAG=-glibc, so no musl entry is read back into it ==="
export CI_PREBUILDS_MUSL_LOADER_GLOB="$WORK/there-is-no-musl-here-*.so.1"
out=$(run_action)
[[ "$(env_value LIBC_TAG)" == "-glibc" ]] \
  || fail "LIBC_TAG is $(env_value LIBC_TAG), not -glibc"

echo "=== a musl image: LIBC_TAG=-musl ==="
: > "$WORK/ld-musl-x86_64.so.1"
export CI_PREBUILDS_MUSL_LOADER_GLOB="$WORK/ld-musl-*.so.1"
out=$(run_action)
[[ "$(env_value LIBC_TAG)" == "-musl" ]] \
  || fail "LIBC_TAG is $(env_value LIBC_TAG), not -musl"

echo "=== an override inside the workspace is stripped to a relative STORE_PATH ==="
export pnpm_config_store_dir="$GITHUB_WORKSPACE/apps/.store"
out=$(run_action)
[[ "$(env_value STORE_PATH)" == "apps/.store" ]] \
  || fail "STORE_PATH is $(env_value STORE_PATH), not apps/.store"
[[ "$(env_value pnpm_config_store_dir)" == "$GITHUB_WORKSPACE/apps/.store" ]] \
  || fail "pnpm lost the absolute store: $(env_value pnpm_config_store_dir)"

echo "=== the act runners bind a host store outside the workspace: that one stays absolute ==="
export pnpm_config_store_dir="$WORK/host-store"
out=$(run_action)
[[ "$(env_value STORE_PATH)" == "$WORK/host-store" ]] \
  || fail "STORE_PATH is $(env_value STORE_PATH), not the absolute $WORK/host-store"

for refused_store in \
  "$GITHUB_WORKSPACE:it is the workspace root" \
  ".pnpm-store:it is not an absolute path" \
  "$GITHUB_WORKSPACE/.pnpm-store/:it ends with a slash" \
  "$GITHUB_WORKSPACE/./.pnpm-store:it holds a dot segment"
do
  store="${refused_store%%:*}"
  reason="${refused_store#*:}"
  echo "=== refused: $store ($reason) ==="
  export pnpm_config_store_dir="$store"
  rc=0
  out=$(run_action) || rc=$?
  [[ "$rc" == "1" ]] || fail "$store exited $rc instead of failing the step"
  echo "$out" | grep -qx "::error::pnpm_config_store_dir=$store is refused: $reason" \
    || fail "the refusal did not name the store and the reason; output was: $out"
  [[ -s "$GITHUB_ENV" ]] && fail "a refused store still exported: $(cat "$GITHUB_ENV")"
done

echo "=== refused: a store path holding a newline, which would write a second line ==="
export pnpm_config_store_dir="$GITHUB_WORKSPACE/.pnpm-store
PATH=/tmp/injected"
rc=0
out=$(run_action) || rc=$?
[[ "$rc" == "1" ]] || fail "a newline in the store path exited $rc instead of failing the step"
echo "$out" | grep -qx "::error::pnpm_config_store_dir is refused: it holds a newline" \
  || fail "the refusal did not name the newline; output was: $out"
grep -q "^PATH=" "$GITHUB_ENV" \
  && fail "the newline injected a second variable into GITHUB_ENV: $(cat "$GITHUB_ENV")"
[[ -s "$GITHUB_ENV" ]] && fail "a refused store still exported: $(cat "$GITHUB_ENV")"

echo "=== no GITHUB_ENV: refused, since the whole job of the action is to export ==="
unset pnpm_config_store_dir
rc=0
out=$(GITHUB_ENV= bash "$ACTION" 2>&1) || rc=$?
[[ "$rc" == "1" ]] || fail "an unset GITHUB_ENV exited $rc instead of failing the step"
echo "$out" | grep -qx "::error::GITHUB_ENV is unset: this action only resolves inside a job" \
  || fail "the refusal did not name GITHUB_ENV; output was: $out"

echo
echo "PASS: all 11 rows"
