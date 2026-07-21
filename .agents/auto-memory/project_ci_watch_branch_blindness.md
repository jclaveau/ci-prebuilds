---
name: ci-watch-script-branch-blindness
description: `pnpm ci:watch:tp` (scripts/ci-watch-one.sh) does `gh run list --workflow=test-and-publish.yml -L1`, latching onto the LATEST run regardless of branch. Surfaces false alarms when a parallel PR run is in flight. For targeted main-branch monitoring after a push, poll a specific run-id directly.
metadata:
  type: project
---

`scripts/ci-watch-one.sh`:
```bash
run=$(gh run list --workflow="$wf" -L1 --json databaseId --jq '.[0].databaseId')
```
This grabs the most recent TP run *across all branches* — so after `git push origin main`, if a feature branch's PR run started later (or was already queued), the watcher latches onto that PR's run instead of the main-branch push.

**Symptom**: watcher reports a failure like `test-playwright-usage (alpine, dood, slim)` on a job/matrix-cell that doesn't correspond to any code path I just touched. Cross-check: `gh run view <id> --json headBranch,displayTitle` — if `headBranch != main` or `displayTitle` doesn't match my commit, it's a false alarm.

**Workaround** — pin the run-id and use `gh run watch` (simpler than the manual loop):

```bash
# 1. find the run for THIS commit (filter by headSha, not just -L1)
HEAD=$(git rev-parse HEAD)
RUN=$(gh run list --workflow=test-and-publish.yml -L 5 --json databaseId,headSha \
       --jq "[.[] | select(.headSha==\"$HEAD\")][0].databaseId")
# 2. watch that specific run in the background
gh run watch "$RUN" --exit-status &
```

**Second failure mode (own back-to-back pushes):** when you push A then push B within seconds,
GitHub auto-cancels A's run and `pnpm ci:watch:tp` may have already latched onto A's databaseId.
The watch then reports `cancelled` even though B's run is in progress / green. Same workaround
applies: re-derive the run-id by `headSha == git rev-parse HEAD` filter after each push, not via
`-L1`.

Could be folded into a new pnpm script (e.g. `ci:watch:tp:head`) if it bites repeatedly.
