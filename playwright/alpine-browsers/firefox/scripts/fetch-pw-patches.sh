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

# browsers.json (from playwright-core on unpkg) — the canonical firefox revision pin.
curl -fsSL "https://unpkg.com/playwright-core@${PW_VERSION}/browsers.json" -o "$OUT/browsers.json"

# UPSTREAM_CONFIG.sh records which Mozilla SHA PW patches were authored against.
curl -fsSL "$GH_RAW/browser_patches/firefox/UPSTREAM_CONFIG.sh" -o "$OUT/UPSTREAM_CONFIG.sh"

# bootstrap.diff — the single rolled patch.
curl -fsSL "$GH_RAW/browser_patches/firefox/patches/bootstrap.diff" -o "$OUT/patches/bootstrap.diff"

# Juggler + preferences — directory trees of new files. The GitHub raw API
# doesn't expose tree listings, so we use the contents API to enumerate then
# raw-fetch each file.
fetch_tree() {
  local subdir="$1"   # e.g. juggler
  local local_dir="$2"
  # GitHub contents API needs a recursive walk; jq builds the file list.
  curl -fsSL "https://api.github.com/repos/microsoft/playwright/git/trees/v${PW_VERSION}?recursive=1" \
    | jq -r --arg p "browser_patches/firefox/$subdir/" '.tree[] | select(.type=="blob" and (.path|startswith($p))) | .path' \
    | while read -r path; do
        rel="${path#browser_patches/firefox/$subdir/}"
        mkdir -p "$local_dir/$(dirname "$rel")"
        curl -fsSL "$GH_RAW/$path" -o "$local_dir/$rel"
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
