#!/usr/bin/env bash
# usage: ci-logs-one.sh <workflow.yml>
# Prints the tail of the first failed job's logs from the latest run of the
# given workflow (timestamps + ANSI stripped). No-op when no failure in the
# latest run.
set -euo pipefail

wf=$1
repo=jclaveau/github-action-container-images

run=$(gh run list --workflow="$wf" -L1 --json databaseId --jq '.[0].databaseId')
job=$(gh api "repos/$repo/actions/runs/$run/jobs" \
        --jq '[.jobs[]|select(.conclusion=="failure")][0] // empty')

if [ -z "$job" ]; then
  echo "no failed job in latest $wf run ($run)"
  exit 0
fi

jid=$(echo "$job" | jq -r .id)
jname=$(echo "$job" | jq -r .name)
echo "=== $jname (id $jid) ==="

gh api "repos/$repo/actions/jobs/$jid/logs" \
  | sed -E 's/^[0-9T:.-]+Z //; s/\x1b\[[0-9;]*m//g' \
  | tail -250
