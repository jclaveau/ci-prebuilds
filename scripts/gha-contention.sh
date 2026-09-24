#!/usr/bin/env bash
# Report how much GitHub-hosted runner capacity this repo is using, and say
# whether a new chain would start promptly or sit in a queue.
#
# The measurement is HOW LONG THE JOBS CURRENTLY QUEUED HAVE BEEN WAITING,
# taken from each job's own `created_at`. Two readings that look like the
# obvious ones are wrong and this avoids both:
#
#   - run-level `status` does not mean what it looks like. A run stays
#     `queued` while ANY of its jobs is queued: run 36005716977 read `queued`
#     with 117 jobs completed and one in progress. "The run has not started"
#     cannot be read off it.
#   - counting queued JOBS conflates two opposite things. A job waiting on
#     `needs:` and a job waiting for a runner both read `queued`, and a
#     160-job chain always has dozens of the first kind, so the count never
#     drops and the gate reads contended forever.
#
# What separates them is that GitHub creates a job when it becomes ELIGIBLE,
# not when its run starts: in run 36013076847, `changes` was created at
# 14:28:34 with the run, while `test-gha-tools-effects` — three layers of
# `needs:` downstream — was created at 14:36:43, seconds after its
# dependencies finished. So for a job still sitting at `queued`,
# `now - created_at` is time spent waiting for a RUNNER, with the dependency
# wait already subtracted. No `needs` graph required, and nothing to sample:
# it is the live queue, measured directly.
#
# GitHub publishes no API for an account's concurrency limit, so nothing here
# guesses one. The job counts are reported as observation; the wait decides.
#
# Every jobs call paginates: the API caps at 100 per page and our chains
# exceed that, so a non-paginated read undercounts.
#
# Usage: gha-contention.sh [--quiet]
# Exit:  0 a new chain would start promptly, 1 it would queue.

set -euo pipefail

REPO="${REPO:-jclaveau/ci-prebuilds}"
# Seconds a job may sit waiting for a runner and still count as room. A
# browser chain runs for hours, so a minute at the door is noise; the budget
# is about telling a short queue from a wall.
WAIT_BUDGET="${GHA_WAIT_BUDGET:-180}"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" = 1 ] || echo "$@"; }

live_runs() {
  local status
  for status in in_progress queued; do
    gh api --paginate "repos/$REPO/actions/runs?status=$status&per_page=100" \
      -q '.workflow_runs[] | [(.id|tostring), .name, .head_branch] | @tsv' \
      2>/dev/null || true
  done
}

now=$(date -u +%s)
running_total=0
queued_total=0
worst_wait=0
worst_job=""
rows=""

while IFS=$'\t' read -r run_id name branch; do
  [ -n "${run_id:-}" ] || continue
  jobs=$(gh api --paginate "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" \
    -q '.jobs[] | [.status, .created_at, .name] | @tsv' 2>/dev/null || true)
  [ -n "$jobs" ] || continue

  run_running=$(printf '%s\n' "$jobs" | awk -F'\t' '$1=="in_progress"' | wc -l)
  run_queued=$(printf '%s\n' "$jobs" | awk -F'\t' '$1=="queued"' | wc -l)
  running_total=$((running_total + run_running))
  queued_total=$((queued_total + run_queued))

  run_worst=0
  while IFS=$'\t' read -r _ created job_name; do
    [ -n "${created:-}" ] || continue
    wait_s=$(( now - $(date -d "$created" +%s) ))
    [ "$wait_s" -gt "$run_worst" ] && run_worst=$wait_s
    if [ "$wait_s" -gt "$worst_wait" ]; then
      worst_wait=$wait_s
      worst_job="$job_name"
    fi
  done < <(printf '%s\n' "$jobs" | awk -F'\t' '$1=="queued"')

  rows="$rows$(printf '  %-11s running %-3s queued %-3s  longest queued %-7s %s @%s' \
    "$run_id" "$run_running" "$run_queued" "${run_worst}s" "$name" "$branch")"$'\n'
done < <(live_runs)

say "GHA contention on $REPO"
say ""
if [ -n "$rows" ]; then say "$(printf '%s' "$rows")"; else say "  (no live runs)"; fi
say ""
say "  $running_total job(s) running, $queued_total waiting for a runner"

if [ "$queued_total" -eq 0 ]; then
  say "  → ROOM: nothing is waiting for a runner"
  exit 0
fi

say "  longest a queued job has waited: ${worst_wait}s (budget ${WAIT_BUDGET}s) — $worst_job"
if [ "$worst_wait" -gt "$WAIT_BUDGET" ]; then
  say "  → CONTENDED: a new chain would queue behind that"
  exit 1
fi
say "  → ROOM: the queue is draining inside ${WAIT_BUDGET}s"
exit 0
