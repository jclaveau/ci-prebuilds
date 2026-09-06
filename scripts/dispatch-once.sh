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
# usage: dispatch-once.sh <workflow-file> <ref> [-f key=value ...]
set -euo pipefail

REPO="${REPO:-jclaveau/ci-prebuilds}"
WF="${1:?workflow file, e.g. playwright-alpine-browsers.yml}"
REF="${2:?git ref}"
shift 2

ids_now() {
  gh run list -R "$REPO" --workflow="$WF" --branch "$REF" --limit 20 \
    --json databaseId --jq '.[].databaseId' 2>/dev/null | sort
}
active() {
  gh run list -R "$REPO" --workflow="$WF" --branch "$REF" --limit 20 \
    --json databaseId,status \
    --jq '.[] | select(.status=="queued" or .status=="in_progress")
          | .databaseId' 2>/dev/null
}

running="$(active || true)"
if [ -n "$running" ]; then
  echo "REFUSING: $WF already queued/running on $REF:" >&2
  echo "$running" | sed 's/^/  https:\/\/github.com\/'"${REPO//\//\\/}"'\/actions\/runs\//' >&2
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

for _ in $(seq 1 20); do
  sleep 6
  new="$(comm -13 <(printf '%s\n' "$before") <(ids_now || true) | head -1)"
  if [ -n "$new" ]; then
    echo "dispatched: https://github.com/$REPO/actions/runs/$new"
    exit 0
  fi
done

echo "no new run appeared within 2 minutes — the dispatch did NOT land." >&2
echo "Safe to retry: the guard above will refuse if it actually did." >&2
exit 4
