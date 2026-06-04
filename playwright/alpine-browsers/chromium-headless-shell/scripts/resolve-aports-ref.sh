#!/usr/bin/env bash
# Resolve which Alpine aports commit shipped a given chromium pkgver. Used by
# the producer to source chromium-headless-shell at a specific Chrome-for-
# Testing version when the active alpine:edge no longer ships it.
#
# Input:   the target chromium version as it appears in
#          `community/chromium/APKBUILD` pkgver, derived earlier from
#          playwright-core@${PW_VERSION}/browsers.json (e.g. 147.0.7727.15).
#          The match is on the `<major>.<minor>.<patch>` prefix — pkgver may
#          carry a fourth `.<build>` segment that doesn't always align with
#          PW's recorded browserVersion.
#
# Output:  the aports commit SHA on stdout (single line).
#
# Algorithm:
#   1. GET the commit history for community/chromium/APKBUILD via gitlab API
#      (paginated newest-first; 100 commits / page).
#   2. For each commit, GET the raw APKBUILD at that ref and grep pkgver=.
#   3. Return the first SHA whose pkgver matches the target prefix.
#   4. Fail loud if no match within 100 commits (~6 months of history) —
#      caller should surface a clearer guidance message ("PW version too
#      old; aports no longer carries that chromium pkgver").
#
# Usage:   resolve-aports-ref.sh 147.0.7727.15
#          → emits "abc1234def…" on stdout
#
# This script runs at producer build time (inside Dockerfile.apk's
# chromium-fetcher stage), NOT at consumer build time. The consumer image
# only sees the resolved apk artifact, never the SHA.

set -euo pipefail

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <chromium-version>" >&2; exit 1; }

# Match on the first three dot-segments only (major.minor.patch). Aports'
# pkgver can include a fourth build segment that doesn't appear in PW's
# browsers.json browserVersion field; treating it as a prefix lets the
# match succeed regardless.
PREFIX=$(echo "$TARGET" | awk -F. '{ print $1 "." $2 "." $3 }')

command -v jq   >/dev/null || { echo "resolve-aports-ref: jq required"   >&2; exit 1; }
command -v curl >/dev/null || { echo "resolve-aports-ref: curl required" >&2; exit 1; }

# URL-encoded project path: alpine/aports → alpine%2Faports.
PROJECT="alpine%2Faports"
COMMITS_URL="https://gitlab.alpinelinux.org/api/v4/projects/${PROJECT}/repository/commits"
RAW_URL_BASE="https://gitlab.alpinelinux.org/alpine/aports/-/raw"

echo "resolve-aports-ref: searching aports for chromium pkgver matching ${PREFIX}.*" >&2

# 100 commits / page; one page is enough for ~6 months of chromium activity.
# If we ever need older history, bump per_page or paginate.
commits_json=$(curl -fsSL "${COMMITS_URL}?path=community/chromium/APKBUILD&per_page=100")

# Iterate newest-first. `< <(…)` (process substitution) keeps the loop in the
# current shell so `exit` propagates, unlike `… | while` which spawns a subshell
# in bash and can't propagate exit codes back.
while read -r sha; do
  # Fetch the APKBUILD at this commit. The raw URL serves the file unchanged;
  # awk grabs the first pkgver line; `tr -d` strips quotes.
  pkgver=$(curl -fsSL "${RAW_URL_BASE}/${sha}/community/chromium/APKBUILD" 2>/dev/null \
    | awk -F= '/^pkgver=/ { print $2; exit }' \
    | tr -d '"' \
    || true)
  [[ -z "$pkgver" ]] && continue

  case "$pkgver" in
    "$PREFIX"*)
      echo "resolve-aports-ref: matched at ${sha} (pkgver=${pkgver})" >&2
      echo "$sha"
      exit 0
      ;;
  esac
done < <(echo "$commits_json" | jq -r '.[].id')

echo "resolve-aports-ref: no aports commit found shipping chromium ${PREFIX}.* within the latest 100 APKBUILD commits" >&2
exit 2
