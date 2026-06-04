#!/usr/bin/env bash
# Consistency guard for playwright/alpine-browsers/versions.env.
#
# Asserts ALPINE_APORTS_CHROMIUM_REF points to an aports commit whose
# community/chromium/APKBUILD pkgver matches PW_VERSION's chromium-headless-shell
# browserVersion (from playwright-core's browsers.json).
#
# Mirrors apply-and-build.sh:43-54's pkgver check at PR time so drift is caught
# in seconds, not after a 30+ minute producer build.
#
# Firefox (ALPINE_APORTS_REF) is INTENTIONALLY NOT checked here — a separate
# WIP pipeline rebuilds firefox-on-Alpine with PW patches and owns that surface.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VERSIONS_ENV="$ROOT/playwright/alpine-browsers/versions.env"

[[ -f "$VERSIONS_ENV" ]] || { echo "FAIL: $VERSIONS_ENV not found" >&2; exit 1; }

set -a
. "$VERSIONS_ENV"
set +a

: "${PW_VERSION:?versions.env missing PW_VERSION}"
: "${ALPINE_APORTS_CHROMIUM_REF:?versions.env missing ALPINE_APORTS_CHROMIUM_REF}"

echo "=== PW $PW_VERSION → derive chromium-headless-shell browserVersion ==="
BROWSERS_JSON=$(curl -fsSL "https://unpkg.com/playwright-core@${PW_VERSION}/browsers.json")
CHS_VER=$(jq -r '.browsers[] | select(.name=="chromium-headless-shell") | .browserVersion' <<<"$BROWSERS_JSON")
if [[ -z "$CHS_VER" || "$CHS_VER" == "null" ]]; then
  echo "FAIL: browsers.json for playwright-core@${PW_VERSION} has no chromium-headless-shell entry" >&2
  exit 1
fi
echo "CHS_VER=$CHS_VER"

echo "=== fetch aports@${ALPINE_APORTS_CHROMIUM_REF} community/chromium/APKBUILD ==="
APKBUILD=$(curl -fsSL "https://gitlab.alpinelinux.org/alpine/aports/-/raw/${ALPINE_APORTS_CHROMIUM_REF}/community/chromium/APKBUILD")
PKGVER=$(echo "$APKBUILD" | awk -F= '/^pkgver=/ { gsub(/"/, "", $2); print $2; exit }')
[[ -n "$PKGVER" ]] || { echo "FAIL: could not parse pkgver from APKBUILD at $ALPINE_APORTS_CHROMIUM_REF" >&2; exit 1; }
echo "PKGVER=$PKGVER"

if [[ "$PKGVER" != "$CHS_VER" ]]; then
  echo "FAIL: aports pkgver=$PKGVER but PW pins CHS_VER=$CHS_VER" >&2
  echo "  Bump ALPINE_APORTS_CHROMIUM_REF in versions.env." >&2
  echo "  The auto-resolve-aports workflow handles this automatically on Renovate PRs;" >&2
  echo "  for hand-edited PW bumps, run:" >&2
  echo "    bash playwright/alpine-browsers/chromium-headless-shell/scripts/resolve-aports-ref.sh $CHS_VER" >&2
  exit 2
fi

echo "PASS: ($PW_VERSION, $ALPINE_APORTS_CHROMIUM_REF) consistent — pkgver=$PKGVER == CHS_VER=$CHS_VER"
