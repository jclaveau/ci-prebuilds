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

files=$(curl -fsSL "$LIST_URL" | jq -r '.[] | select(.type=="blob") | .name')

[[ -z "$files" ]] && { echo "fetch-aports: no files at ref=$REF (gitlab API empty)" >&2; exit 1; }

for f in $files; do
  raw="https://gitlab.alpinelinux.org/alpine/aports/-/raw/$REF/community/chromium/$f"
  echo "  fetch $f"
  curl -fsSL "$raw" -o "$OUT/$f"
done

echo "aports community/chromium fetched to $OUT ($(ls -1 "$OUT" | wc -l) files)"
