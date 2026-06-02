#!/usr/bin/env bash
# Fetch microsoft/playwright's firefox patches + Juggler at the version pinned in versions.env.
#
# Usage: fetch-pw-patches.sh <out_dir>
# Reads: PW_VERSION (from versions.env)
# Writes:
#   <out_dir>/UPSTREAM_CONFIG.sh       (informational — records the FF SHA PW pinned against)
#   <out_dir>/patches/bootstrap.diff   (the patch to apply on Firefox source)
#   <out_dir>/juggler/                 (the Juggler automation protocol — new files)
#   <out_dir>/preferences/             (Firefox prefs PW sets at runtime)
#   <out_dir>/browsers.json            (PW's canonical browser pin manifest; we read firefox.revision from this)

set -euo pipefail

OUT="${1:?usage: fetch-pw-patches.sh <out_dir>}"
PW_VERSION="${PW_VERSION:?PW_VERSION must be set}"

mkdir -p "$OUT/patches" "$OUT/juggler" "$OUT/preferences"

# We fetch from unpkg's mirror of the published `playwright-core` npm package
# rather than the playwright GitHub tree at a tag — npm is the contract, and the
# tarball is the same artifact PW ships, with deterministic content per version.
#
# But: `playwright-core` on npm does NOT include `browser_patches/`. The patches
# live in the `microsoft/playwright` GitHub repo, tagged `v<PW_VERSION>`. We
# pull from GitHub at the matching tag.

GH_RAW="https://raw.githubusercontent.com/microsoft/playwright/v${PW_VERSION}"

# raw.githubusercontent.com + api.github.com rate-limit unauthenticated traffic
# to ~60 req/hr per IP. The glibc-debug path (no buildcache hit) downloads
# 100+ Juggler files in one RUN and hits the limit mid-loop, surfacing as a
# 403. Pass GITHUB_TOKEN via curl --header when available — it bumps the limit
# to 5000 req/hr. In the producer Dockerfile, the secret is forwarded via
# --secret=id=github-token (or via build-arg / env), then read here.
#
# Plus a 3-try retry with backoff: transient 403/429 in mid-fetch shouldn't
# kill the whole 100-file walk.
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
retry_curl() {
  local n=1
  while (( n <= 3 )); do
    if curl -fsSL "${AUTH_HEADER[@]}" "$@"; then
      return 0
    fi
    echo "  retry $n/3 (rate limit?) — sleep $((n*5))s" >&2
    sleep $((n*5))
    n=$((n+1))
  done
  return 1
}

# browsers.json (from playwright-core on unpkg) — the canonical firefox revision pin.
retry_curl "https://unpkg.com/playwright-core@${PW_VERSION}/browsers.json" -o "$OUT/browsers.json"

# UPSTREAM_CONFIG.sh records which Mozilla SHA PW patches were authored against.
retry_curl "$GH_RAW/browser_patches/firefox/UPSTREAM_CONFIG.sh" -o "$OUT/UPSTREAM_CONFIG.sh"

# bootstrap.diff — the single rolled patch.
retry_curl "$GH_RAW/browser_patches/firefox/patches/bootstrap.diff" -o "$OUT/patches/bootstrap.diff"

# Juggler + preferences — directory trees of new files. The GitHub raw API
# doesn't expose tree listings, so we use the contents API to enumerate then
# raw-fetch each file.
fetch_tree() {
  local subdir="$1"   # e.g. juggler
  local local_dir="$2"
  # GitHub contents API needs a recursive walk; jq builds the file list.
  retry_curl "https://api.github.com/repos/microsoft/playwright/git/trees/v${PW_VERSION}?recursive=1" \
    | jq -r --arg p "browser_patches/firefox/$subdir/" '.tree[] | select(.type=="blob" and (.path|startswith($p))) | .path' \
    | while read -r path; do
        rel="${path#browser_patches/firefox/$subdir/}"
        mkdir -p "$local_dir/$(dirname "$rel")"
        retry_curl "$GH_RAW/$path" -o "$local_dir/$rel"
      done
}

fetch_tree juggler "$OUT/juggler"
fetch_tree preferences "$OUT/preferences"

# Extract the firefox revision + version PW pinned, for downstream scripts.
FF_REV=$(jq -r '.browsers[] | select(.name=="firefox") | .revision' "$OUT/browsers.json")
FF_VER=$(jq -r '.browsers[] | select(.name=="firefox") | .browserVersion' "$OUT/browsers.json")
echo "PW v${PW_VERSION} pins firefox revision=${FF_REV} browserVersion=${FF_VER}"
echo "${FF_REV}" > "$OUT/.firefox-revision"
echo "${FF_VER}" > "$OUT/.firefox-version"
