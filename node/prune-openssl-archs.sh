#!/bin/bash
# prune-openssl-archs.sh <prefix>: keeps only this machine's OpenSSL arch headers under
# <prefix>/include/node/openssl/archs. node's install ships all 21 (55.5 MiB, 3,090 files, the bulk
# of the image's file count after node itself), and a native addon compiles against one of them.
set -euo pipefail

archs_dir="$1/include/node/openssl/archs"
machine_arch=$(uname -m)
case "$machine_arch" in
  x86_64) kept_arch=linux-x86_64 ;;
  aarch64) kept_arch=linux-aarch64 ;;
  *)
    printf 'prune-openssl-archs: no OpenSSL arch mapped for machine %q\n' "$machine_arch" >&2
    exit 1
    ;;
esac
if [ ! -d "$archs_dir/$kept_arch" ]; then
  printf 'prune-openssl-archs: %q holds no %q directory\n' "$archs_dir" "$kept_arch" >&2
  exit 1
fi
find "$archs_dir" -mindepth 1 -maxdepth 1 ! -name "$kept_arch" -exec rm -rf {} +
