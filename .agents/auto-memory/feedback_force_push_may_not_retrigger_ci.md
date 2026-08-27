---
name: feedback_force_push_may_not_retrigger_ci
description: A rebase force-push can leave a PR with ZERO runs at the new sha, and "no checks reported" is indistinguishable from "nobody has looked at it" — assert a run exists at the new head, then kick with an empty commit
metadata:
  type: feedback
---

After rebasing `perf/webkit-fastfmod` `--onto main` and force-pushing, `gh pr
checks 131` answered **"no checks reported on the branch"**. Not red, not
pending — nothing had been created at the new sha, so the PR looked exactly
like one nobody had touched. The pre-rebase sha's runs were all green and still
attached to the PR's history, which made it read as checked.

Why it bites harder than a normal missing run: the green runs from the OLD sha
are right there in the timeline, so a glance at the PR says "green" while the
code actually under review has never been built. On this PR that meant `Test
and Publish` never produced the consumer image the whole measurement depended
on, and I sat waiting for a build that was never going to start.

**Assert, do not assume.** After any force-push:

```
gh run list --branch <br> --limit 5 --json headSha,workflowName,status
```

and check a run exists whose `headSha` is the NEW head — not merely that runs
exist. If none: push an empty commit
(`git commit --allow-empty`) to redeliver the webhook, which worked here
immediately. A `workflow_dispatch --ref <branch>` is the other trampoline but
only reaches workflows that have one.

Related but distinct: [[feedback_gha_silent_webhook_hiccup]] is about a push
producing no run at all; this is about a FORCE-push specifically, where stale
green runs disguise the gap. And retargeting a PR's base via REST does not
re-fire `pull_request` either, so a rebase + retarget can miss twice.
[[feedback_watch_ci_after_push]]
