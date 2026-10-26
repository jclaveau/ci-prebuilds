#!/bin/sh
# `actions/setup-node` resolves a version from the runner tool cache before it downloads anything,
# and a node sitting in /usr/bin is not in that layout. Registering the installed node as symlinks
# makes `tc.find` hit it: no second node in the image, and on Alpine no glibc tarball (the only
# build the actions/node-versions manifest offers) landing over a musl one.
set -eu

if [ -z "${RUNNER_TOOL_CACHE:-}" ]; then
  echo "RUNNER_TOOL_CACHE is unset, so there is no tool cache to register node in" >&2
  exit 1
fi

node_version=$(node -p process.versions.node)
# tool-cache keys its arch dir on os.arch(), which is what process.arch reports.
arch_dir="$RUNNER_TOOL_CACHE/node/$node_version/$(node -p process.arch)"
mkdir -p "$arch_dir/bin"

for required_binary in node npm; do
  binary_path=$(command -v "$required_binary") || {
    echo "$required_binary is missing: install it before registering node in the tool cache" >&2
    exit 1
  }
  ln -sfn "$binary_path" "$arch_dir/bin/$required_binary"
done

for optional_binary in npx corepack; do
  if binary_path=$(command -v "$optional_binary"); then
    ln -sfn "$binary_path" "$arch_dir/bin/$optional_binary"
  else
    echo "$optional_binary absent from this image, left out of the tool cache"
  fi
done

# The marker `tc.find` checks for, as a sibling of the arch dir it validates.
: >| "$arch_dir.complete"

echo "node $node_version registered at $arch_dir"
