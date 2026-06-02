#!/usr/bin/env bash
# Rename the chromium-dist tree into the directory shape PW SDK expects for
# auto-discovery via PLAYWRIGHT_BROWSERS_PATH.
#
# Source layout (from apply-and-build.sh):
#   /work/chromium-dist/
#     chrome-headless-shell  ← binary (renamed from headless_shell)
#     icudtl.dat, *.bin, *.pak, locales/, …
#
# Target layout (what PW SDK reads at launch time):
#   ${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-${CHS_REV}/
#     chrome-headless-shell-linux64/
#       chrome-headless-shell
#       icudtl.dat, *.bin, *.pak, locales/, …
#     INSTALLATION_COMPLETE        ← empty marker; PW checks for this
#
# This script outputs the inner `chrome-headless-shell-linux64/` tree under
# /work/chromium-shell-linux64/ — the Dockerfile's artifact stage COPYs that
# into the scratch image at /chrome-headless-shell-linux64. The consumer
# Dockerfile then re-layouts into the registry directory + marker.

set -euo pipefail

WORK="${1:?usage: stage-cache-layout.sh <work_dir>}"
DIST="$WORK/chromium-dist"
OUT="$WORK/chrome-headless-shell-linux64"

[[ -d "$DIST" ]] || { echo "missing $DIST (apply-and-build.sh ran?)" >&2; exit 1; }

# Chromium's GN target outputs `headless_shell` as the binary name; PW expects
# `chrome-headless-shell`. Rename + create the wrapper layout.
if [[ -f "$DIST/headless_shell" && ! -f "$DIST/chrome-headless-shell" ]]; then
  mv "$DIST/headless_shell" "$DIST/chrome-headless-shell"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$DIST/." "$OUT/"

echo "Staged cache layout at $OUT:"
ls -lh "$OUT" | head -20
