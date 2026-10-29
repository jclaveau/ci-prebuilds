#!/bin/sh
# Adds `<version> <sha256>` for nodejs.org's musl tarball to node/node-musl-sha256.txt, which
# node/Dockerfile.alpine requires for every NODE_VERSION it builds. The sha comes from
# unofficial-builds' SHASUMS256.txt AND from hashing the downloaded tarball; both must agree.
# The host signs neither, so this records what it served on the day it was pinned: a later swap
# on the host fails the image build instead of shipping.
set -eu

case "${1:-}" in
  [0-9]*.[0-9]*.[0-9]*) node_version=$1 ;;
  *) echo "usage: $0 <node version, e.g. 24.22.1>" >&2; exit 1 ;;
esac

repo_root=$(cd "$(dirname "$0")/.." && pwd)
sha_file="$repo_root/node/node-musl-sha256.txt"
tarball="node-v${node_version}-linux-x64-musl.tar.xz"
release_url="https://unofficial-builds.nodejs.org/download/release/v${node_version}"

if awk -v v="$node_version" '$1 == v { found = 1 } END { exit !found }' "$sha_file"; then
  echo "node $node_version is already pinned in $sha_file" >&2
  exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

listed_sha=$(curl -fsSL "$release_url/SHASUMS256.txt" | awk -v f="$tarball" '$2 == f { print $1 }')
if [ -z "$listed_sha" ]; then
  echo "$release_url/SHASUMS256.txt lists no $tarball (not built yet? unofficial-builds lags" \
    "nodejs.org by about a day)" >&2
  exit 1
fi
curl -fsSLo "$work_dir/$tarball" "$release_url/$tarball"
hashed_sha=$(sha256sum "$work_dir/$tarball" | cut -d' ' -f1)
if [ "$hashed_sha" != "$listed_sha" ]; then
  echo "$tarball hashes to $hashed_sha but SHASUMS256.txt lists $listed_sha" >&2
  exit 1
fi

echo "$node_version $hashed_sha" >> "$sha_file"
echo "pinned node $node_version $hashed_sha"
