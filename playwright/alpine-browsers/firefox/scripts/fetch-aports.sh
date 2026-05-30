#!/usr/bin/env bash
# Fetch community/firefox from gitlab.alpinelinux.org/alpine/aports.
#
# Usage: fetch-aports.sh <out_dir>
# Reads: ALPINE_APORTS_REF (from versions.env)
# Writes: <out_dir>/{APKBUILD, *.patch, mozconfig, ...}
#
# We curl individual files via the GitLab API rather than `git clone` the whole
# aports repo (~hundreds of MB, mostly irrelevant). The community/firefox tree
# is small (~20 files).

set -euo pipefail

OUT="${1:?usage: fetch-aports.sh <out_dir>}"
REF="${ALPINE_APORTS_REF:?ALPINE_APORTS_REF must be set}"

mkdir -p "$OUT"

API="https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports"
LIST_URL="$API/repository/tree?path=community/firefox&ref=$REF&per_page=100"

# List then fetch each file. jq parses the GitLab API response.
files=$(curl -fsSL "$LIST_URL" | jq -r '.[] | select(.type=="blob") | .name')

[[ -z "$files" ]] && { echo "fetch-aports: no files at ref=$REF (gitlab API returned nothing)" >&2; exit 1; }

for f in $files; do
  raw="https://gitlab.alpinelinux.org/alpine/aports/-/raw/$REF/community/firefox/$f"
  echo "  fetch $f"
  curl -fsSL "$raw" -o "$OUT/$f"
done

echo "aports community/firefox fetched to $OUT ($(ls -1 "$OUT" | wc -l) files)"
