#!/usr/bin/env bash
# Fetch Playwright's pinned browser revisions from upstream — the single source
# of truth for ALL browser variants we build (chromium-headless-shell, firefox,
# eventually webkit).
#
# Reads PW_VERSION from versions.env, downloads
#   https://unpkg.com/playwright-core@${PW_VERSION}/browsers.json
# and exports per-browser revision + browserVersion + downloadPaths into the
# caller's environment via key=value lines on stdout.
#
# Usage:
#   eval "$(./fetch-pw-browsers-json.sh chromium-headless-shell)"
#   echo $CHROMIUM_HEADLESS_SHELL_REVISION  # → 1226
#   echo $CHROMIUM_HEADLESS_SHELL_VERSION   # → 149.0.7827.22
#
# Output env-var naming: ${BROWSER_UPPER}_REVISION, ${BROWSER_UPPER}_VERSION,
# ${BROWSER_UPPER}_DOWNLOAD_LINUX64 (the CfT / PW CDN URL we'd otherwise GET).
# Dashes in the browser name become underscores: chromium-headless-shell →
# CHROMIUM_HEADLESS_SHELL_REVISION.
#
# Argument: one or more browser names exactly as they appear in PW's
# browsers.json `browsers[].name` field. With no args, dumps all.
#
# Intended caller: apply-and-build.sh, or any other producer step that needs
# to anchor its build artifacts to PW's pin without a second source-of-truth.

set -euo pipefail

WORK="${WORK:-/work}"
VERSIONS_ENV="${VERSIONS_ENV:-$WORK/versions.env}"
CACHE_PATH="${PW_BROWSERS_JSON_CACHE:-$WORK/pw-browsers.json}"

[[ -f "$VERSIONS_ENV" ]] || { echo "missing $VERSIONS_ENV" >&2; exit 1; }

# shellcheck disable=SC1090
. "$VERSIONS_ENV"

[[ -n "${PW_VERSION:-}" ]] || { echo "PW_VERSION not set in $VERSIONS_ENV" >&2; exit 1; }

if [[ ! -f "$CACHE_PATH" ]]; then
  echo "fetch-pw-browsers-json: GET playwright-core@${PW_VERSION}/browsers.json" >&2
  curl -fsSL "https://unpkg.com/playwright-core@${PW_VERSION}/browsers.json" -o "$CACHE_PATH"
fi

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

# Argument handling: emit only requested browsers, or all if no args.
if [[ $# -eq 0 ]]; then
  BROWSERS=$(jq -r '.browsers[].name' "$CACHE_PATH")
else
  BROWSERS="$*"
fi

for browser in $BROWSERS; do
  # PW's browsers.json: each entry has .name, .revision, .browserVersion,
  # .installByDefault. We don't need installByDefault — the consumer picks.
  rev=$(jq -r --arg n "$browser" '.browsers[] | select(.name==$n) | .revision' "$CACHE_PATH")
  ver=$(jq -r --arg n "$browser" '.browsers[] | select(.name==$n) | .browserVersion' "$CACHE_PATH")
  if [[ -z "$rev" || "$rev" == "null" ]]; then
    echo "fetch-pw-browsers-json: no entry for browser '$browser' in pw-browsers.json" >&2
    exit 2
  fi
  # NAME_UPPER → for env var prefix. Dashes → underscores.
  prefix=$(echo "$browser" | tr 'a-z-' 'A-Z_')
  printf '%s_REVISION=%s\n' "$prefix" "$rev"
  printf '%s_VERSION=%s\n' "$prefix" "$ver"
done
