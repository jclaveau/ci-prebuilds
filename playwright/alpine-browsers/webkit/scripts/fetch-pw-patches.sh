#!/usr/bin/env bash
# Fetch microsoft/playwright's webkit patches at the version pinned in versions.env.
#
# Usage: fetch-pw-patches.sh <out_dir>
# Reads: PW_VERSION (from versions.env)
# Writes:
#   <out_dir>/UPSTREAM_CONFIG.sh       (records the WebKit SHA PW pinned against)
#   <out_dir>/patches/                 (PW's patch series — applied in order)
#   <out_dir>/embedder/                (PW's MiniBrowser embedder source overrides)
#   <out_dir>/pw_run.sh                (the launcher PW ships in the artifact — copied verbatim)
#   <out_dir>/browsers.json            (PW's canonical browser pin manifest)

set -euo pipefail

OUT="${1:?usage: fetch-pw-patches.sh <out_dir>}"
PW_VERSION="${PW_VERSION:?PW_VERSION must be set}"

mkdir -p "$OUT/patches" "$OUT/embedder"

# Patch series ref — see PW_WEBKIT_PATCHES_REF in versions.env. Defaults to the
# release tag so the script still works standalone.
PW_PATCHES_REF="${PW_WEBKIT_PATCHES_REF:-v${PW_VERSION}}"
GH_RAW="https://raw.githubusercontent.com/microsoft/playwright/${PW_PATCHES_REF}"

# Same retry + auth shape as firefox/scripts/fetch-pw-patches.sh — raw.gh +
# api.gh rate-limit unauthenticated traffic to ~60/hr per IP and a fresh fetch
# walks dozens of patch + embedder files in one RUN. GITHUB_TOKEN is forwarded
# via Docker secret/build-arg/env in CI.
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

retry_curl "https://unpkg.com/playwright-core@${PW_VERSION}/browsers.json" -o "$OUT/browsers.json"
retry_curl "$GH_RAW/browser_patches/webkit/UPSTREAM_CONFIG.sh" -o "$OUT/UPSTREAM_CONFIG.sh"
retry_curl "$GH_RAW/browser_patches/webkit/pw_run.sh" -o "$OUT/pw_run.sh"
chmod +x "$OUT/pw_run.sh"

# patches/ and embedder/ are directory trees — walk via the GitHub git-trees API.
fetch_tree() {
  local subdir="$1"
  local local_dir="$2"
  retry_curl "https://api.github.com/repos/microsoft/playwright/git/trees/${PW_PATCHES_REF}?recursive=1" \
    | jq -r --arg p "browser_patches/webkit/$subdir/" '.tree[] | select(.type=="blob" and (.path|startswith($p))) | .path' \
    | while read -r path; do
        rel="${path#browser_patches/webkit/$subdir/}"
        mkdir -p "$local_dir/$(dirname "$rel")"
        retry_curl "$GH_RAW/$path" -o "$local_dir/$rel"
      done
}

fetch_tree patches "$OUT/patches"
fetch_tree embedder "$OUT/embedder"

WK_REV=$(jq -r '.browsers[] | select(.name=="webkit") | .revision' "$OUT/browsers.json")
WK_VER=$(jq -r '.browsers[] | select(.name=="webkit") | .browserVersion' "$OUT/browsers.json")
WK_SHA=$(awk -F= '$1=="BASE_REVISION"{gsub(/[" ]/,"",$2); print $2; exit}' "$OUT/UPSTREAM_CONFIG.sh")
echo "PW v${PW_VERSION} pins webkit revision=${WK_REV} browserVersion=${WK_VER}; patches from ${PW_PATCHES_REF} (upstream SHA=${WK_SHA})"
echo "${WK_REV}" > "$OUT/.webkit-revision"
echo "${WK_VER}" > "$OUT/.webkit-version"
echo "${WK_SHA}" > "$OUT/.webkit-sha"
