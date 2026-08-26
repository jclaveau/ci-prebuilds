#!/usr/bin/env bash
# Fetch community/chromium from gitlab.alpinelinux.org/alpine/aports.
#
# We pull aports' APKBUILD + *.patch files (musl-side patches: sandbox-musl,
# tid-caching-musl, etc.) so we can build Chromium for musl on top of vanilla
# upstream Chromium source. PW does NOT ship Chromium patches — they download
# Google's CfT prebuilt — so this script is the only patch source. Mirror of
# `firefox/scripts/fetch-aports.sh` (same shape, different community/ dir).
#
# Usage: fetch-aports.sh <out_dir>
# Reads: ALPINE_APORTS_CHROMIUM_REF (from versions.env)
# Writes: <out_dir>/{APKBUILD, *.patch, *.gn, ...}

set -euo pipefail

OUT="${1:?usage: fetch-aports.sh <out_dir>}"
REF="${ALPINE_APORTS_CHROMIUM_REF:?ALPINE_APORTS_CHROMIUM_REF must be set}"

mkdir -p "$OUT"

API="https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports"
LIST_URL="$API/repository/tree?path=community/chromium&ref=$REF&per_page=100"

# gitlab.alpinelinux.org drops connections: run 32892351327 lost a whole Firefox
# round to `curl: (28) Failed to connect ... after 133306 ms`, and the aports
# fetch was the only un-retried curl left in the build. Same 3-try shape as
# firefox/scripts/fetch-pw-patches.sh — duplicated rather than shared because
# each image COPYs only its own scripts/ dir. --connect-timeout so a dead socket
# fails fast enough for the retries to fit inside the step.
retry_curl() {
  local n=1
  while (( n <= 3 )); do
    if curl -fsSL --connect-timeout 20 "$@"; then
      return 0
    fi
    echo "  retry $n/3 (gitlab unreachable?) — sleep $((n*5))s" >&2
    sleep $((n*5))
    n=$((n+1))
  done
  return 1
}

files=$(retry_curl "$LIST_URL" | jq -r '.[] | select(.type=="blob") | .name')

[[ -z "$files" ]] && { echo "fetch-aports: no files at ref=$REF (gitlab API empty)" >&2; exit 1; }

for f in $files; do
  raw="https://gitlab.alpinelinux.org/alpine/aports/-/raw/$REF/community/chromium/$f"
  echo "  fetch $f"
  retry_curl "$raw" -o "$OUT/$f"
done

echo "aports community/chromium fetched to $OUT ($(ls -1 "$OUT" | wc -l) files)"
