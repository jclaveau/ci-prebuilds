#!/usr/bin/env bash
# Dispatch a workflow at most once, and confirm it by observing the run rather
# than by trusting the reply.
#
# Why this exists: `gh workflow run` is a mutating remote command. When its
# reply is lost — a TLS handshake timeout, a dropped link — the dispatch has
# ALREADY executed server-side, and the obvious retry fires it a second time.
# That happened on an informational probe and cost nothing; the same mistake on
# a 25-30 h chromium chain costs a day of runner time and produces two arms
# nobody asked for.
#
# Two guards, because they fail differently:
#   - before: refuse if a run for this workflow is already queued or running on
#     this ref. That is the "my retry already landed" case.
#   - after: poll for a run id that did not exist before the POST, instead of
#     believing the POST. `gh run list --limit 1` straight after a dispatch
#     routinely returns the PREVIOUS still-finishing run.
#
# usage: dispatch-once.sh <workflow-file> <ref> [--jobs <job-prefix>] [-f key=value ...]
#
# --jobs narrows "already running" to one pipeline inside a workflow that
# hosts several, e.g. --jobs build-webkit while a chromium chain is live.
set -euo pipefail

REPO="${REPO:-jclaveau/ci-prebuilds}"
WF="${1:?workflow file, e.g. playwright-alpine-browsers.yml}"
REF="${2:?git ref}"
shift 2

# Optional flavour: --jobs <prefix>. playwright-alpine-browsers.yml runs several
# unrelated pipelines behind one workflow file, and its own `concurrency:` key
# already separates them (pab-<ref>-wk, -ff, -chs-source, …) so they run in
# parallel by design. A guard keyed on the workflow alone therefore refuses a
# webkit dispatch because a 25-30 h chromium chain is live, which is not the
# double-fire this exists to prevent — and that lockout lasts a day.
#
# With --jobs, "already running" means a live run that owns a job whose name
# starts with the prefix. A live webkit build still blocks a webkit dispatch,
# which is the case that matters.
JOBS_PREFIX=""
if [ "${1:-}" = "--jobs" ]; then
  JOBS_PREFIX="${2:?--jobs needs a job-name prefix, e.g. build-webkit}"
  shift 2
fi

# Fails when `gh` fails, instead of returning an empty listing: piping into
# `sort` would hand back sort's exit status, so a dropped connection read as
# "this ref has no runs" — which is what made the confirmation loop below
# declare two landed dispatches dead.
ids_now() {
  local out
  out="$(gh run list -R "$REPO" --workflow="$WF" --branch "$REF" --limit 20 \
    --json databaseId --jq '.[].databaseId' 2>/dev/null)" || return 1
  printf '%s\n' "$out" | sort
}
active() {
  gh run list -R "$REPO" --workflow="$WF" --branch "$REF" --limit 20 \
    --json databaseId,status \
    --jq '.[] | select(.status=="queued" or .status=="in_progress")
          | .databaseId' 2>/dev/null
}
# A run counts for THIS flavour when it has a job with the prefix that is not
# finished. A run still spawning its jobs has none yet, so it counts too —
# refusing on an ambiguous run is the safe direction for a guard.
owns_flavour() {
  local id="$1" n
  [ -n "$JOBS_PREFIX" ] || return 0
  n=$(gh run view "$id" -R "$REPO" --json jobs \
        --jq "[.jobs[] | select(.name | startswith(\"$JOBS_PREFIX\"))] | length" \
      2>/dev/null || echo 0)
  [ "${n:-0}" -eq 0 ] && return 1
  n=$(gh run view "$id" -R "$REPO" --json jobs \
        --jq "[.jobs[] | select(.name | startswith(\"$JOBS_PREFIX\"))
               | select(.conclusion == null or .conclusion == \"\")] | length" \
      2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ]
}

blocking=""
for id in $(active || true); do
  if owns_flavour "$id"; then
    blocking="$blocking$id
"
  fi
done
if [ -n "$blocking" ]; then
  echo "REFUSING: $WF already queued/running on $REF${JOBS_PREFIX:+ for $JOBS_PREFIX}:" >&2
  printf '%s' "$blocking" | sed 's/^/  https:\/\/github.com\/'"${REPO//\//\\/}"'\/actions\/runs\//' >&2
  echo "If that is a stale run rather than your own retry, cancel it first." >&2
  exit 3
fi

before="$(ids_now || true)"

# The POST itself is allowed to fail at the transport layer without the caller
# retrying it — that is the whole point. Whether it took is decided below, by
# looking for a new run id.
set +e
gh workflow run "$WF" -R "$REPO" --ref "$REF" "$@"
post_rc=$?
set -e
[ "$post_rc" -eq 0 ] || echo "note: the dispatch POST returned $post_rc;" \
  "checking whether it landed anyway" >&2

# Five minutes, and every listing failure counted rather than swallowed.
#
# Two dispatches in a row were reported as "did NOT land" while both had
# landed: 34140776274 registered as a queued run about 3 minutes after the
# POST, and 34142548027 appeared right at the edge of the old 2-minute window.
# Between them the local link was also dropping `gh` calls outright ("error
# connecting to api.github.com"), which `ids_now` swallowed into an empty
# listing indistinguishable from "no new run".
#
# The direction of the error matters here. This guard exists to stop a SECOND
# dispatch of a multi-hour chain, so a false "did not land" is the dangerous
# outcome, not a slow confirmation: it invites exactly the retry the script was
# written to prevent.
polls=50
misses=0
for _ in $(seq 1 "$polls"); do
  sleep 6
  listing="$(ids_now)" || { misses=$((misses + 1)); continue; }
  new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$listing") | head -1)"
  if [ -n "$new" ]; then
    echo "dispatched: https://github.com/$REPO/actions/runs/$new"
    exit 0
  fi
done

if [ "$misses" -gt 0 ]; then
  echo "COULD NOT CONFIRM: $misses of $polls run listings failed outright," \
    "so an unseen run is not the same as an absent one." >&2
  echo "Check before retrying:" \
    "gh run list -R $REPO --workflow=$WF --branch $REF" >&2
  exit 5
fi
echo "no new run appeared within 5 minutes — the dispatch did NOT land." >&2
echo "Safe to retry: the guard above will refuse if it actually did." >&2
exit 4
