#!/usr/bin/env bash
# Unit test for the shared FF prebuilt-base patch-set hash.
#
# Exists because the rule was hand-listed in two workflows and the list omitted
# bundle-dist.sh — which IS baked into the base and DOES change the artifact.
# Editing it therefore reused a stale base and shipped nothing, the same class
# of miss that shipped an unpatched ff-latest on 2026-07-28.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
HASHER="$ROOT/playwright/alpine-browsers/firefox/patchset-hash.sh"

failures=0
checks=0

fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
check() { checks=$((checks + 1)); }

# A scratch copy we can mutate, so the tests exercise the real script against a
# real tree instead of asserting against its source.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/playwright/alpine-browsers"
cp -a "$ROOT/playwright/alpine-browsers/versions.env" \
      "$scratch/playwright/alpine-browsers/"
cp -a "$ROOT/playwright/alpine-browsers/firefox" \
      "$scratch/playwright/alpine-browsers/"

baseline=$(bash "$HASHER" "$scratch")

check
if ! [[ "$baseline" =~ ^[0-9a-f]{12}$ ]]; then
  fail "hash is not 12 hex chars: '$baseline'"
fi

# The regression under test: bundle-dist.sh must be inside the hashed set.
check
echo '# mutation' >> "$scratch/playwright/alpine-browsers/firefox/scripts/bundle-dist.sh"
if [ "$(bash "$HASHER" "$scratch")" = "$baseline" ]; then
  fail "editing bundle-dist.sh did not change the hash — a stale base would be reused"
fi
git -C "$ROOT" show HEAD:playwright/alpine-browsers/firefox/scripts/bundle-dist.sh \
  > "$scratch/playwright/alpine-browsers/firefox/scripts/bundle-dist.sh" 2>/dev/null \
  || cp -a "$ROOT/playwright/alpine-browsers/firefox/scripts/bundle-dist.sh" \
           "$scratch/playwright/alpine-browsers/firefox/scripts/bundle-dist.sh"

# ...and the iter script must stay outside it: it runs against an already-seeded
# base, so touching it must not force a ~5h cold reseed.
check
restored=$(bash "$HASHER" "$scratch")
echo '# mutation' >> "$scratch/playwright/alpine-browsers/firefox/scripts/apply-and-build-iter.sh"
if [ "$(bash "$HASHER" "$scratch")" != "$restored" ]; then
  fail "editing apply-and-build-iter.sh changed the hash — that forces a needless cold reseed"
fi

# Every file the base image bakes in must be hashed. If a COPY is added to
# Dockerfile.prebuilt-base, this fails and the hasher has to be revisited.
check
copies=$(grep -E '^COPY ' "$ROOT/playwright/alpine-browsers/Dockerfile.prebuilt-base" \
         | awk '{print $2}' | LC_ALL=C sort | paste -sd,)
expected="firefox/mozconfig.overlay,firefox/scripts,versions.env"
if [ "$copies" != "$expected" ]; then
  fail "Dockerfile.prebuilt-base COPY set changed: '$copies' != '$expected' — patchset-hash.sh may now miss a baked-in file"
fi

# Neither workflow may re-implement the rule inline; that is how the two copies
# drifted apart in the first place.
for wf in playwright-alpine-browsers.yml playwright-alpine-browsers-prebuilt-base.yml; do
  check
  if ! grep -q 'patchset-hash.sh' "$ROOT/.github/workflows/$wf"; then
    fail "$wf does not call the shared patchset-hash.sh"
  fi
  check
  if grep -q 'PATCHSET_HASH=$(cat' "$ROOT/.github/workflows/$wf"; then
    fail "$wf still computes the patch-set hash inline"
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "patchset-hash: $failures/$checks checks failed" >&2
  exit 1
fi
echo "patchset-hash: $checks checks passed"
