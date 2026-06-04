---
name: on-demand-prepare-failure-ux
description: comment-close job must run on `always()`, not `prepare.result == 'success'`, or pre-flight rejections leave the issue with no feedback
metadata:
  type: project
---

**Symptom:** PR 41 added pre-flight `docker manifest inspect chs-${CHS_REV}` in `on-demand-build.yml` `prepare` job. When PW 1.59.1 was requested with chs-1217 not yet published, prepare failed correctly — but the issue got **no comment**. Requester sees only a workflow failure email; no actionable retry box.

**Root cause:** `comment-close.if: prepare.result == 'success'` — entire commenting flow gated on prepare succeeding.

**Fix (PR 42):**
- `comment-close.if: always() && contains(github.event.issue.labels.*.name, 'build-request')`
- New "Comment prepare failure + label" step: fires on `needs.prepare.result != 'success'`, posts `:x: Build request rejected at the prepare stage` with retry checkbox.
- Existing build-failure step tightened to `prepare.result == 'success' && build.result != 'success'` so the two failure paths don't both fire.

**Why:** UX rule for build-request issues — every dispatch outcome (success, prepare-fail, build-fail) MUST produce an issue comment. The issue is the user's UI; silent workflow failures are user-hostile.

**How to apply:** When adding new prepare-stage validations (e.g. future FF version pre-flight), don't gate the comment job on the new check passing. The "prepare failure" comment step already covers it as long as `needs.prepare.result != 'success'`.
