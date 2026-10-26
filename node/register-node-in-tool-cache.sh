#!/bin/sh
# `actions/setup-node` resolves a version from the runner tool cache before it downloads anything,
# and a node sitting in /usr/bin is not in that layout. Registering the installed node as symlinks
# makes `tc.find` hit it: no second node in the image, and on Alpine no glibc tarball (the only
# build the actions/node-versions manifest offers) landing over a musl one.
set -eu

case "${RUNNER_TOOL_CACHE:-}" in
  '')
    echo "RUNNER_TOOL_CACHE is unset, so there is no tool cache to register node in" >&2
    exit 1
    ;;
  /*) ;;
  *)
    echo "RUNNER_TOOL_CACHE=$RUNNER_TOOL_CACHE is relative, so a job would resolve it against its" \
      "own working directory and find nothing" >&2
    exit 1
    ;;
esac

# The cache root is 2775 so that a job running under a host uid of its own can still cache a tool
# there; once node/ exists every later version lands inside it, so these dirs must carry that too.
umask 002

for required_binary in node npm; do
  command -v "$required_binary" >/dev/null || {
    echo "$required_binary is missing: install it before registering node in the tool cache" >&2
    exit 1
  }
done

node_version=$(node -p process.versions.node)
# tool-cache keys the arch dir on `process.arch`, bar 32-bit arm, which `setup-node` looks up as
# armv7l — no image here builds for it.
arch_dir="$RUNNER_TOOL_CACHE/node/$node_version/$(node -p process.arch)"
mkdir -p "$arch_dir/bin"

for tool_binary in node npm npx corepack; do
  binary_path=$(command -v "$tool_binary") || {
    echo "$tool_binary absent from this image, left out of the tool cache"
    continue
  }
  ln -sfn "$binary_path" "$arch_dir/bin/$tool_binary"
done

# The marker `tc.find` checks for, as a sibling of the arch dir it validates.
: > "$arch_dir.complete"

echo "node $node_version registered at $arch_dir"
