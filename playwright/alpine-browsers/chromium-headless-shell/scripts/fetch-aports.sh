#!/usr/bin/env bash
# Fetch community/chromium from alpine's aports, pinned to
# ALPINE_APORTS_CHROMIUM_REF.
#
# We pull aports' APKBUILD + *.patch files (musl-side patches: sandbox-musl,
# tid-caching-musl, etc.) so we can build Chromium for musl on top of vanilla
# upstream Chromium source. PW does NOT ship Chromium patches — they download
# Google's CfT prebuilt — so this script is the only patch source. Mirror of
# `firefox/scripts/fetch-aports.sh` (same shape, different community/ dir).
#
# Usage: fetch-aports.sh <out_dir>
# Reads: ALPINE_APORTS_CHROMIUM_REF (from versions.env)
# Writes: <out_dir>/{APKBUILD, *.patch, *.gn, ...}

set -euo pipefail

OUT="${1:?usage: fetch-aports.sh <out_dir>}"
REF="${ALPINE_APORTS_CHROMIUM_REF:?ALPINE_APORTS_CHROMIUM_REF must be set}"

mkdir -p "$OUT"

# gitlab.alpinelinux.org is intermittently unreachable from GHA runners, and it
# fails at minute one of a multi-hour build. On 2026-08-27 it killed three
# separate firefox builds with `curl: (28) Connection timed out`; the old budget
# here was 3 tries and ~75 s total, which is nothing against an outage lasting
# minutes. Chromium's exposure is worse than firefox's, not better — this runs
# at the head of a chain whose cold path is 25-30 h.
#
# Worse, it does not READ as a network fault: this script owns its retry loop,
# so exhausting it returns non-zero and BuildKit blames the `RUN` line of the
# Dockerfile — i.e. whichever build script the branch happened to change. Every
# message here names the network explicitly for that reason.
#
# Two levers, both cheap next to a 25 h compile:
#   - a wider budget: 5 rounds, 30 s connect timeout, backoff 5/10/20/30 s
#   - a SECOND HOST. github.com/alpinelinux/aports is a true mirror, verified at
#     THIS package's pinned sha 124cc885 rather than inherited from firefox's
#     check against a different ref: the same 25-file listing from both hosts,
#     and a byte-identical APKBUILD (md5 ea152f1882c767aed832842caf3286e0).
#     A fallback beats more retries against one dead host.
# Overridable so the fallback test can run all three cases in seconds rather
# than in the six minutes the real budget takes.
ATTEMPTS="${APORTS_ATTEMPTS:-5}"
CONNECT_TIMEOUT="${APORTS_CONNECT_TIMEOUT:-30}"
MAX_TIME="${APORTS_MAX_TIME:-180}"

GL_API="https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports"
GL_LIST="$GL_API/repository/tree?path=community/chromium&ref=$REF&per_page=100"
GL_RAW="https://gitlab.alpinelinux.org/alpine/aports/-/raw/$REF/community/chromium"

GH_LIST="https://api.github.com/repos/alpinelinux/aports/contents/community/chromium?ref=$REF"
GH_RAW="https://raw.githubusercontent.com/alpinelinux/aports/$REF/community/chromium"

# Overridable so the fallback can be EXERCISED rather than assumed — a fallback
# that has never executed is not a fallback. tests/fetch-aports-fallback.sh
# points the primary at an unroutable host and asserts the github leg returns
# byte-identical files.
GL_LIST="${APORTS_GL_LIST_OVERRIDE:-$GL_LIST}"
GL_RAW="${APORTS_GL_RAW_OVERRIDE:-$GL_RAW}"
# The mirror is overridable too, so the test can blackhole BOTH hosts and prove
# the failure path still fails. A failover case that cannot be shown to fail
# when it should is not evidence that it succeeded for the right reason.
GH_LIST="${APORTS_GH_LIST_OVERRIDE:-$GH_LIST}"
GH_RAW="${APORTS_GH_RAW_OVERRIDE:-$GH_RAW}"

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
        # Say so whenever the primary did NOT serve it, not only after a sleep:
        # a build quietly running entirely off the mirror is worth seeing in the
        # log before the mirror is the one that breaks.
        if (( n > 1 )) || [[ "$host" == github ]]; then
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

echo "aports community/chromium fetched to $OUT ($(ls -1 "$OUT" | wc -l) files)"
