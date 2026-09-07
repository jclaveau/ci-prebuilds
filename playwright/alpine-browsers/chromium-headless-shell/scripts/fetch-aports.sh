#!/usr/bin/env bash
# Fetch community/chromium from alpine's aports, pinned to
# ALPINE_APORTS_CHROMIUM_REF.
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

# Both hosts, the wide retry budget and the failure message all live in the
# shared helper — this file only says WHICH files it wants. See aports-fetch.sh
# for why gitlab alone is not enough.
. "$(dirname "${BASH_SOURCE[0]}")/aports-fetch.sh"

GL_LIST="$APORTS_GL_BASE/api/v4/projects/alpine%2Faports/repository/tree?path=community/chromium&ref=$REF&per_page=100"
GH_LIST="$APORTS_GH_API_BASE/repos/alpinelinux/aports/contents/community/chromium?ref=$REF"

# GitLab calls them "blob", GitHub calls them "file" — accept either so one
# listing parser serves both hosts.
aports_fetch "file listing" "$GL_LIST" "$GH_LIST" -o "$OUT/.listing.json"
files=$(jq -r '.[] | select(.type=="blob" or .type=="file") | .name' "$OUT/.listing.json")
rm -f "$OUT/.listing.json"

if [[ -z "$files" ]]; then
  echo "fetch-aports: no files at ref=$REF (listing empty — wrong ref?)" >&2
  exit 1
fi

for f in $files; do
  echo "  fetch $f"
  aports_raw "$REF" "community/chromium/$f" -o "$OUT/$f"
done

echo "aports community/chromium fetched to $OUT ($(ls -1 "$OUT" | wc -l) files)"
