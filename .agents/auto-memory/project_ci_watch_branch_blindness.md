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

**Workaround** for main-branch monitoring after a push:
```bash
RUN=$(gh run list --workflow=test-and-publish.yml --branch main -L1 --json databaseId --jq '.[0].databaseId')
while :; do
  j=$(gh run view "$RUN" --json status,conclusion,jobs --jq '{s:.status,c:.conclusion,f:[.jobs[]|select(.conclusion=="failure")|.name][0]}')
  s=$(echo "$j" | jq -r .s); c=$(echo "$j" | jq -r .c); f=$(echo "$j" | jq -r .f)
  [ -n "$f" ] && [ "$f" != null ] && { echo "FAIL: $f"; exit 0; }
  [ "$s" = completed ] && { echo "DONE: $c"; exit 0; }
  sleep 30
done
```

Could be folded into a new pnpm script (e.g. `ci:watch:tp:main`) if it bites repeatedly.
