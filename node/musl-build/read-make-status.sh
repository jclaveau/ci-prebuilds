#!/usr/bin/env bash
# Reads the build stage's /make-status ("done" or "unfinished") into the
# step's make_status output.
set -euo pipefail

status_file=$1
make_status=$(cat "$status_file")
case "$make_status" in
  done) ;;
  unfinished) echo "::notice::make ran out of its budget: pushing the resume point for the next round" ;;
  *)
    echo "unexpected make status $(printf '%q' "$make_status") in $status_file" >&2
    exit 1
    ;;
esac
echo "make_status=$make_status" >> "$GITHUB_OUTPUT"
