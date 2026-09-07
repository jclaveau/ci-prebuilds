#!/usr/bin/env bash
# Every read of alpine's aports, over TWO hosts. Sourced, never executed:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/aports-fetch.sh"
#
# gitlab.alpinelinux.org is intermittently unreachable from GHA runners. On
# 2026-08-27 it killed three separate firefox builds with `curl: (28)`, and it
# fails at minute one of a chain whose cold path is 25-30 h. It also does not
# READ as a network fault: a script that owns its own retry loop returns
# non-zero when the loop exhausts, and BuildKit then blames the `RUN` line of
# whichever file the branch happened to change. Every message below names the
# network explicitly for that reason.
#
# Two levers, both cheap next to the build they gate:
#   - a wider budget: 5 rounds, 30 s connect timeout, backoff 5/10/20/30 s
#   - a SECOND HOST. github.com/alpinelinux/aports is a true mirror, verified
#     at this package's pinned sha: same listing, byte-identical APKBUILD.
#     A fallback beats more retries against one dead host.
#
# This file exists because the first pass hardened the fetch and left four
# other call sites reading gitlab directly — including the one the unit test
# drives, which is how the PR went red on an outage it was written to survive.
# One reason, one implementation: harden here and every consumer inherits it.

APORTS_ATTEMPTS="${APORTS_ATTEMPTS:-5}"
APORTS_CONNECT_TIMEOUT="${APORTS_CONNECT_TIMEOUT:-30}"
APORTS_MAX_TIME="${APORTS_MAX_TIME:-180}"

# Host bases, overridable so the failover can be EXERCISED rather than assumed,
# and so ONE variable blackholes a host for every consumer at once.
APORTS_GL_BASE="${APORTS_GL_BASE:-https://gitlab.alpinelinux.org}"
APORTS_GH_API_BASE="${APORTS_GH_API_BASE:-https://api.github.com}"
APORTS_GH_RAW_BASE="${APORTS_GH_RAW_BASE:-https://raw.githubusercontent.com}"

# Which host answered last. resolve-aports-ref.sh walks up to 100 commits and
# fetches an APKBUILD for each, so without this an outage costs the gitlab
# connect timeout ONCE PER COMMIT — 100 × 30 s — before the mirror serves every
# one of them. Remembering the working host turns that back into one timeout.
#
# It is a file, not a variable, because callers read us inside `$(…)`: a
# subshell cannot write state back to its parent. `$$` is the parent shell's
# pid even inside those subshells, so the file is per-run and needs no cleanup
# beyond /tmp's.
APORTS_STATE="${APORTS_STATE:-${TMPDIR:-/tmp}/aports-host.$$}"

aports_preferred_host() { cat "$APORTS_STATE" 2>/dev/null || echo gitlab; }

# Try both hosts, then back off and try both again. `what` is only for the
# message, so a failure says which artifact AND which host, not just a URL.
aports_fetch() {
  local what="$1" primary="$2" fallback="$3"
  shift 3
  local n=1 url host backoff order
  local preferred; preferred="$(aports_preferred_host)"
  if [[ "$preferred" == github ]]; then order="github gitlab"; else order="gitlab github"; fi
  while (( n <= APORTS_ATTEMPTS )); do
    for host in $order; do
      if [[ "$host" == gitlab ]]; then
        url="$primary"
      else
        url="$fallback"
      fi
      if curl -fsSL --connect-timeout "$APORTS_CONNECT_TIMEOUT" \
              --max-time "$APORTS_MAX_TIME" "$url" "$@"; then
        echo "$host" >"$APORTS_STATE" 2>/dev/null || true
        # Say so whenever the host CHANGED, not only after a sleep: a build
        # quietly running entirely off the mirror is worth seeing in the log
        # before the mirror is the one that breaks. Only on the change, or the
        # resolver's 100-commit scan would print it 100 times.
        if (( n > 1 )) || [[ "$host" != "$preferred" ]]; then
          echo "  recovered: $what from $host on round $n" >&2
        fi
        return 0
      fi
      echo "  NETWORK: $what unreachable at $host (round $n/$APORTS_ATTEMPTS)" >&2
    done
    if (( n < APORTS_ATTEMPTS )); then
      backoff=$(( n * 5 < 30 ? n * 5 : 30 ))
      echo "  NETWORK: both hosts failed, sleeping ${backoff}s" >&2
      sleep "$backoff"
    fi
    n=$((n+1))
  done
  echo "aports-fetch: NETWORK FAILURE — $what unreachable at BOTH" >&2
  echo "  gitlab.alpinelinux.org and github.com after $APORTS_ATTEMPTS rounds." >&2
  echo "  This is an upstream/network fault, NOT the build scripts. BuildKit" >&2
  echo "  will attribute it to the Dockerfile RUN line; ignore that." >&2
  return 1
}

aports_gl_raw() { echo "$APORTS_GL_BASE/alpine/aports/-/raw/$1/$2"; }
aports_gh_raw() { echo "$APORTS_GH_RAW_BASE/alpinelinux/aports/$1/$2"; }

# aports_raw <ref> <repo-path> [curl args…] — one file at one ref.
aports_raw() {
  local ref="$1" path="$2"
  shift 2
  aports_fetch "$path@${ref:0:8}" \
    "$(aports_gl_raw "$ref" "$path")" "$(aports_gh_raw "$ref" "$path")" "$@"
}

# aports_commits <repo-path> [per_page] — sha per line, newest first.
aports_commits() {
  local path="$1" per="${2:-100}" json
  json=$(aports_fetch "commit history for $path" \
    "$APORTS_GL_BASE/api/v4/projects/alpine%2Faports/repository/commits?path=$path&per_page=$per" \
    "$APORTS_GH_API_BASE/repos/alpinelinux/aports/commits?path=$path&per_page=$per") || return 1
  # gitlab names the sha `id`, github names it `sha`; neither carries the
  # other's key, so one expression reads both shapes.
  jq -r '.[] | .id // .sha' <<<"$json"
}
