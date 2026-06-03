#!/usr/bin/env bash
# usage: ci-watch-one.sh <workflow.yml> <label>
# Resolves the latest run for <workflow.yml>, polls every 15s, and prints
# either the first failed job name OR the final conclusion. Exits 0 either
# way — the caller decides what to do with the printed line.
set -euo pipefail

wf=$1
label=$2

run=$(gh run list --workflow="$wf" -L1 --json databaseId --jq '.[0].databaseId')
echo "watching $label=$run"

while true; do
  j=$(gh run view "$run" --json status,conclusion,jobs \
       --jq '{s:.status, c:.conclusion, f:[.jobs[]|select(.conclusion=="failure")|.name][0]}')
  f=$(echo "$j" | jq -r .f)
  s=$(echo "$j" | jq -r .s)
  c=$(echo "$j" | jq -r .c)
  if [ -n "$f" ] && [ "$f" != null ]; then
    echo "--- $label first failure: $f ---"
    exit 0
  fi
  if [ "$s" = "completed" ]; then
    echo "--- $label: $c ---"
    exit 0
  fi
  sleep 15
done
