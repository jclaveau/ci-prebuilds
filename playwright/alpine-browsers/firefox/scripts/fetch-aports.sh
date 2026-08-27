#!/usr/bin/env bash
# Fetch community/firefox from alpine's aports, pinned to ALPINE_APORTS_REF.
#
# Usage: fetch-aports.sh <out_dir>
# Reads: ALPINE_APORTS_REF (from versions.env)
# Writes: <out_dir>/{APKBUILD, *.patch, mozconfig, ...}
#
# We curl individual files rather than `git clone` the whole aports repo
# (~hundreds of MB, mostly irrelevant). The community/firefox tree is ~23 files.

set -euo pipefail

OUT="${1:?usage: fetch-aports.sh <out_dir>}"
REF="${ALPINE_APORTS_REF:?ALPINE_APORTS_REF must be set}"

mkdir -p "$OUT"

# gitlab.alpinelinux.org is intermittently unreachable from GHA runners, and it
# fails at minute one of a 4-hour build. On 2026-08-27 it killed three separate
# firefox builds with `curl: (28) Connection timed out after 20002 ms`, twice on
# the same branch; the old budget was 3 tries and ~75 s total, which is nothing
# against an outage lasting minutes.
#
# Worse, it does not READ as a network fault: this script owns its retry loop,
# so exhausting it returns non-zero and BuildKit blames the `RUN` line of the
# Dockerfile — i.e. whichever build script the branch happened to change. Every
# message here names the network explicitly for that reason.
#
# Two levers, both cheap next to a 4 h compile:
#   - a wider budget: 5 rounds, 30 s connect timeout, backoff 5/10/20/30 s
#   - a SECOND HOST. github.com/alpinelinux/aports is a true mirror, verified at
#     the pinned sha 66e79518: same 23-file listing and a byte-identical
#     APKBUILD (md5 28baf980f0c6602e8a8683548774ca86) as gitlab serves. A
#     fallback beats more retries against one dead host.
ATTEMPTS=5
CONNECT_TIMEOUT=30
MAX_TIME=180

GL_API="https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports"
GL_LIST="$GL_API/repository/tree?path=community/firefox&ref=$REF&per_page=100"
GL_RAW="https://gitlab.alpinelinux.org/alpine/aports/-/raw/$REF/community/firefox"

GH_LIST="https://api.github.com/repos/alpinelinux/aports/contents/community/firefox?ref=$REF"
GH_RAW="https://raw.githubusercontent.com/alpinelinux/aports/$REF/community/firefox"

# Try both hosts, then back off and try both again. `what` is only for the
# message, so a failure says which artifact AND which host, not just a URL.
fetch_both_hosts() {
  local what="$1" primary="$2" fallback="$3"
  shift 3
  local n=1 url host backoff
  while (( n <= ATTEMPTS )); do
    for host in gitlab github; do
      if [[ "$host" == gitlab ]]; then
        url="$primary"
      else
        url="$fallback"
      fi
      if curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
              "$url" "$@"; then
        if (( n > 1 )); then
          echo "  recovered: $what from $host on round $n" >&2
        fi
        return 0
      fi
      echo "  NETWORK: $what unreachable at $host (round $n/$ATTEMPTS)" >&2
    done
    if (( n < ATTEMPTS )); then
      backoff=$(( n * 5 < 30 ? n * 5 : 30 ))
      echo "  NETWORK: both hosts failed, sleeping ${backoff}s" >&2
      sleep "$backoff"
    fi
    n=$((n+1))
  done
  echo "fetch-aports: NETWORK FAILURE — $what unreachable at BOTH" >&2
  echo "  gitlab.alpinelinux.org and github.com after $ATTEMPTS rounds." >&2
  echo "  This is an upstream/network fault, NOT the build scripts. BuildKit" >&2
  echo "  will attribute it to the Dockerfile RUN line; ignore that." >&2
  return 1
}

# GitLab calls them "blob", GitHub calls them "file" — accept either so one
# listing parser serves both hosts.
fetch_both_hosts "file listing" "$GL_LIST" "$GH_LIST" -o "$OUT/.listing.json"
files=$(jq -r '.[] | select(.type=="blob" or .type=="file") | .name' "$OUT/.listing.json")
rm -f "$OUT/.listing.json"

if [[ -z "$files" ]]; then
  echo "fetch-aports: no files at ref=$REF (listing empty — wrong ref?)" >&2
  exit 1
fi

for f in $files; do
  echo "  fetch $f"
  fetch_both_hosts "$f" "$GL_RAW/$f" "$GH_RAW/$f" -o "$OUT/$f"
done

echo "aports community/firefox fetched to $OUT ($(ls -1 "$OUT" | wc -l) files)"
