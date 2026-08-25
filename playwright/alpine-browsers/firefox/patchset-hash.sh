#!/usr/bin/env bash
# Content-address the FF prebuilt-base on its patch SET, not just PW's rev.
#
# A source-only patch (the Juggler location fix, the bundle-dist strip pass)
# leaves PW's firefox revision unchanged, so a rev-only base tag lets the iter
# path reuse a stale pre-patch base and ship an unpatched ff-latest. We shipped
# exactly that on 2026-07-28.
#
# The set to hash is "whatever Dockerfile.prebuilt-base bakes into the image":
#
#   COPY versions.env              /work/versions.env
#   COPY firefox/scripts           /work/firefox/scripts
#   COPY firefox/mozconfig.overlay /work/firefox/mozconfig.overlay
#
# It is derived from the directory rather than hand-listed. The hand-listed
# version silently omitted bundle-dist.sh, which is baked in and does affect
# the artifact — so edits to it reused a stale base and never shipped.
#
# Lives outside firefox/scripts/ on purpose: a file in there would be baked in
# and would hash itself, reseeding a ~5h build whenever this logic changed.
#
# Both playwright-alpine-browsers.yml and
# playwright-alpine-browsers-prebuilt-base.yml call this. They MUST agree — the
# consumer's auto-select looks up prebuilt-base-ff-<rev>-<hash>, so two
# implementations that drift apart mean a base that is never found.
#
# Usage: patchset-hash.sh [repo_root]   (default: cwd)

set -euo pipefail

ROOT="${1:-.}"
BROWSERS="$ROOT/playwright/alpine-browsers"

# apply-and-build-iter.sh is deliberately out: it runs at iter time against an
# already-seeded base, so changing it must not force a cold reseed.
mapfile -t FILES < <(
  {
    printf '%s\n' "$BROWSERS/versions.env" "$BROWSERS/firefox/mozconfig.overlay"
    find "$BROWSERS/firefox/scripts" -type f ! -name 'apply-and-build-iter.sh'
  } | LC_ALL=C sort
)

# An empty or short list would still produce a stable hash, and would silently
# content-address the base on nothing. Fail instead.
if [ "${#FILES[@]}" -lt 5 ]; then
  echo "patchset-hash: expected >=5 files, found ${#FILES[@]}" >&2
  printf '  %s\n' "${FILES[@]}" >&2
  exit 1
fi
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "patchset-hash: missing $f" >&2; exit 1; }
done

cat "${FILES[@]}" | sha256sum | cut -c1-12
