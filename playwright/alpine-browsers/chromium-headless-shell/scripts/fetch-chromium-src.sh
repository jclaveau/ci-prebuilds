#!/usr/bin/env bash
# Fetch Chromium source at the version PW pins for chromium-headless-shell.
#
# We bypass depot_tools entirely. depot_tools pulls ~30 GB of history + DEPS
# submodules; for a one-shot build we can grab the source tarball Google
# publishes alongside each tagged release at:
#   https://commondatastorage.googleapis.com/chromium-browser-official/chromium-<VER>.tar.xz
# Plus the testdata tarball:
#   https://commondatastorage.googleapis.com/chromium-browser-official/chromium-<VER>-testdata.tar.xz
# (we don't need testdata for headless_shell — skip it).
#
# Usage: fetch-chromium-src.sh <out_dir>
# Reads: CHROMIUM_HEADLESS_SHELL_VERSION (from fetch-pw-browsers-json.sh)
# Writes: <out_dir>/chromium-<VER>/  (extracted Chromium source tree)

set -euo pipefail

OUT="${1:?usage: fetch-chromium-src.sh <out_dir>}"
VER="${CHROMIUM_HEADLESS_SHELL_VERSION:?CHROMIUM_HEADLESS_SHELL_VERSION must be set}"

mkdir -p "$OUT"

TARBALL="chromium-${VER}.tar.xz"
URL="https://commondatastorage.googleapis.com/chromium-browser-official/$TARBALL"
TARGET="$OUT/$TARBALL"

if [[ -d "$OUT/chromium-${VER}" && -f "$OUT/chromium-${VER}/BUILD.gn" ]]; then
  echo "chromium source already extracted at $OUT/chromium-${VER}"
  exit 0
fi

if [[ ! -f "$TARGET" ]]; then
  echo "fetch-chromium-src: GET $URL (~3 GB)"
  curl -fSL "$URL" -o "$TARGET"
fi

echo "fetch-chromium-src: extract $TARBALL"
tar -xJf "$TARGET" -C "$OUT"
[[ -d "$OUT/chromium-${VER}" ]] || { echo "fetch-chromium-src: tarball didn't unpack to expected dir chromium-${VER}" >&2; exit 1; }

# Free up runner disk — the tarball is huge.
rm -f "$TARGET"

echo "chromium source ready at $OUT/chromium-${VER}"
