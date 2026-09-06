#!/usr/bin/env bash
# Exercise BOTH legs of fetch-aports.sh, because a fallback that has never
# executed is not a fallback — it is a comment.
#
# Three cases, and the third is what makes the other two mean anything:
#
#   1. normal    both hosts up; gitlab serves. Establishes the reference bytes.
#   2. failover  gitlab blackholed; github must serve BYTE-IDENTICAL files.
#                This is the case that fires in the outage being defended
#                against.
#   3. both down both hosts blackholed; the script MUST fail. Without it, case 2
#                could be passing for the wrong reason — e.g. if the fetch were
#                silently writing nothing and returning 0, cases 1 and 2 would
#                both "pass" and diff clean against each other.
#   4. resolver   the same failover through resolve-aports-ref.sh, which is the
#                script the PR-time unit test drives and the one that actually
#                went red. It reads a different pair of URLs whose JSON shape
#                differs per host, so case 2 does not cover it.
#
# 192.0.2.1 is TEST-NET-1 (RFC 5737), a routable-looking address that goes
# nowhere. Deliberately not a bogus hostname: DNS failure and connection failure
# are different code paths in curl, and a blackholed address is the closer
# analogue of the real outage.
#
# usage: ALPINE_APORTS_CHROMIUM_REF=<sha> tests/fetch-aports-fallback.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH="$HERE/../scripts/fetch-aports.sh"
: "${ALPINE_APORTS_CHROMIUM_REF:?set it, e.g. from playwright/alpine-browsers/versions.env}"
export ALPINE_APORTS_CHROMIUM_REF

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# One round, 3 s connect: the point is to prove which host answered, not to sit
# through the six-minute production budget.
export APORTS_ATTEMPTS=1 APORTS_CONNECT_TIMEOUT=3
# One knob per host, and it blackholes that host for EVERY consumer of
# aports-fetch.sh — which is what makes case 4 below cost two lines.
DEAD="https://192.0.2.1"

echo "=== 1. normal: both hosts reachable"
if bash "$FETCH" "$TMP/normal" > "$TMP/normal.log" 2>&1; then
  echo "    ok — $(ls -1 "$TMP/normal" | wc -l) files"
else
  echo "    FAILED (is the network up?)"
  cat "$TMP/normal.log"
  fail=1
fi

echo "=== 2. failover: gitlab blackholed, github must serve identical bytes"
if APORTS_GL_BASE="$DEAD" \
   bash "$FETCH" "$TMP/failover" > "$TMP/failover.log" 2>&1; then
  echo "    ok — $(ls -1 "$TMP/failover" | wc -l) files"
else
  echo "    FAILED — the github leg did not serve"
  cat "$TMP/failover.log"
  fail=1
fi
# It must have actually gone to the mirror, not quietly succeeded on gitlab.
if ! grep -q "from github" "$TMP/failover.log" 2>/dev/null; then
  echo "    VACUOUS — nothing in the log says github served it"
  fail=1
fi

if [[ -d "$TMP/normal" && -d "$TMP/failover" ]]; then
  if diff -r "$TMP/normal" "$TMP/failover" > "$TMP/diff.log" 2>&1; then
    echo "    bytes identical across hosts"
  else
    echo "    MISMATCH — the mirror is not a mirror:"
    cat "$TMP/diff.log"
    fail=1
  fi
  # Two empty trees diff clean and prove nothing.
  n=$(ls -1 "$TMP/failover" | wc -l)
  if [[ "$n" -lt 5 ]]; then
    echo "    VACUOUS — only $n files; the comparison checked nothing"
    fail=1
  fi
  if [[ ! -s "$TMP/failover/APKBUILD" ]]; then
    echo "    VACUOUS — no APKBUILD in the failover tree"
    fail=1
  fi
fi

echo "=== 3. both hosts blackholed: must FAIL"
if APORTS_GL_BASE="$DEAD" APORTS_GH_API_BASE="$DEAD" APORTS_GH_RAW_BASE="$DEAD" \
   bash "$FETCH" "$TMP/dead" > "$TMP/dead.log" 2>&1; then
  echo "    FAILED — it reported success with both hosts unreachable"
  fail=1
else
  echo "    ok — failed as required"
fi

echo "=== 4. resolve-aports-ref over the mirror: gitlab blackholed"
# The script that went red on 2026-08-27 — it reads aports twice (commit
# history, then one APKBUILD per commit) and both reads now share this fetch.
# Case 2 proves the fetcher fails over; this proves the RESOLVER does, which is
# a different pair of URLs and a different JSON shape per host.
RESOLVE="$HERE/../scripts/resolve-aports-ref.sh"
CHS_VER="${CHS_VER:-148.0.7778.96}"
if SHA=$(APORTS_GL_BASE="$DEAD" APORTS_ATTEMPTS=1 APORTS_CONNECT_TIMEOUT=3 \
         bash "$RESOLVE" "$CHS_VER" 2>"$TMP/resolve.log"); then
  if [[ "$SHA" =~ ^[0-9a-f]{8,}$ ]]; then
    echo "    ok — resolved $SHA off the mirror"
  else
    echo "    FAILED — expected a hex sha, got: $SHA"
    fail=1
  fi
else
  echo "    FAILED — the github leg did not serve the resolver"
  cat "$TMP/resolve.log"
  fail=1
fi
if ! grep -q "from github" "$TMP/resolve.log" 2>/dev/null; then
  echo "    VACUOUS — nothing in the log says github served it"
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL"
  exit 1
fi
echo "PASS"
