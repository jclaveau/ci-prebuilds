#!/usr/bin/env bash
# The whole body of the pnpm-store action. A file of its own, not an inline `run:`, so
# tests/scripts/test-pnpm-store.sh can run every row of it without a runner.
set -euo pipefail

if [ -z "${GITHUB_WORKSPACE:-}" ]; then
  echo "::error::GITHUB_WORKSPACE is unset: this action only resolves inside a job"
  exit 1
fi

# Exporting is the whole job of this action, so a job it cannot export to is refused here
# rather than left to the cache step, which fails on an empty `path:` three steps later.
if [ -z "${GITHUB_ENV:-}" ]; then
  echo "::error::GITHUB_ENV is unset: this action only resolves inside a job"
  exit 1
fi

# actions/cache tars every entry relative to $GITHUB_WORKSPACE, so a store outside it
# restores into ../../../ - which is / in a job container, where uid 1001 cannot mkdir. A
# relative path is also one same string on the host and in a container, so both land on a
# single cache version instead of one entry each.
store_dir="${pnpm_config_store_dir:-$GITHUB_WORKSPACE/.pnpm-store}"

# A value holding a newline writes a second GITHUB_ENV line, so `store_dir=<path>\nPATH=…`
# would hand every later step of the job that PATH. Refused on its own, and without
# echoing the value back: that is the one refusal whose message a raw value would split.
newline='
'
case "$store_dir" in
  *"$newline"*)
    echo "::error::pnpm_config_store_dir is refused: it holds a newline"
    exit 1 ;;
esac

# STORE_PATH is hashed into the cache version, so a trailing slash or a dot segment
# survives the strip below as a second version under the one key - the very split this
# action closes; $GITHUB_WORKSPACE itself would cache the whole checkout under the key.
case "$store_dir" in
  "$GITHUB_WORKSPACE") refusal="it is the workspace root" ;;
  [!/]*) refusal="it is not an absolute path" ;;
  */) refusal="it ends with a slash" ;;
  */.|*/..|*/./*|*/../*) refusal="it holds a dot segment" ;;
  "$GITHUB_WORKSPACE"/*) ;;
  # act binds a host store outside the workspace and serves it back from its own cache
  # server, so there the absolute path is the point. On a GHA runner it is the ../../../
  # restore above, which this action exists to close.
  *) [ -n "${ACT:-}" ] \
    || refusal="it is outside the workspace actions/cache tars against" ;;
esac
if [ -n "${refusal:-}" ]; then
  echo "::error::pnpm_config_store_dir=$store_dir is refused: $refusal"
  exit 1
fi

cache_path="$store_dir"
# the act runners bind a host store outside the workspace: that one stays absolute
case "$store_dir" in
  "$GITHUB_WORKSPACE"/*) cache_path="${store_dir#"$GITHUB_WORKSPACE"/}" ;;
esac

libc=glibc
# musl resolves other optional deps and compiles other native addons than glibc, so each
# libc needs its own entry: one Linux-pnpm-store-<hash> served both, whichever arm wrote
# it first. Probing the loader needs no binary the image might not ship. The glob is a
# variable only so the test can point it at a file it owns.
for musl_loader in ${CI_PREBUILDS_MUSL_LOADER_GLOB:-/lib/ld-musl-*.so.1}; do
  if [ -e "$musl_loader" ]; then libc=musl; fi
done

export_variable() { # <name> <value>
  echo "$1=$2" >> "$GITHUB_ENV"
  echo "$1=$2" # the step logged nothing before: a cache miss starts being read here
}

export_variable pnpm_config_store_dir "$store_dir"
export_variable STORE_PATH "$cache_path"
export_variable LIBC_TAG "-$libc"
