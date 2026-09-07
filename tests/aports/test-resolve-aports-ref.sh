#!/usr/bin/env bash
# Unit test for chromium-headless-shell/scripts/resolve-aports-ref.sh.
#
# Happy path: a known-good chromium pkgver resolves to a hex aports SHA.
# Sad path:   a fabricated pkgver returns "no aports commit found".
#
# Network-dependent — it reads aports for real, over both hosts
# (see chromium-headless-shell/scripts/aports-fetch.sh).

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../../playwright/alpine-browsers/chromium-headless-shell/scripts/resolve-aports-ref.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found or not executable" >&2; exit 1; }

echo "=== happy: known pkgver 148.0.7778.96 (versions.env's currently-pinned value) ==="
SHA=$("$SCRIPT" 148.0.7778.96)
if [[ ! "$SHA" =~ ^[0-9a-f]{8,}$ ]]; then
  echo "FAIL: expected hex SHA, got: $SHA" >&2
  exit 1
fi
echo "PASS: $SHA"

echo "=== sad: pkgver 999.0.0.0 (will never exist) ==="
STDERR=$(mktemp)
trap 'rm -f "$STDERR"' EXIT
if "$SCRIPT" 999.0.0.0 2>"$STDERR"; then
  echo "FAIL: expected non-zero exit on bogus pkgver" >&2
  exit 1
fi
if ! grep -q "no aports commit found" "$STDERR"; then
  echo "FAIL: stderr missing 'no aports commit found' marker" >&2
  cat "$STDERR" >&2
  exit 1
fi
echo "PASS: failed loudly as expected"

echo "ALL OK"
