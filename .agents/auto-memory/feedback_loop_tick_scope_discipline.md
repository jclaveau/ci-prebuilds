---
name: feedback_loop_tick_scope_discipline
description: a /loop tick must report only the chains/PRs named in its prompt; a red found while diagnosing a NAMED red stays in scope, an open-PR sweep does not
metadata:
  type: feedback
---

Jean: "why do you spealk about PW 1.63, out of scope for now" (2026-09-24).
Ticks had drifted into reporting every open PR's status (PW 1.63 bump, PRs
#234/#313) even though the standing `/loop` prompt named only PR 310, which
had already merged — so the open-PR sweep had no mandate left and kept
running anyway out of habit.

**Why:** a `/loop` prompt is a scope contract, not a floor. Once its only
named PR merges, continuing to scan and report all open PRs is unrequested
work that dilutes the tick and buries the chains actually being tracked.

**How to apply:** each tick, report only what the current `/loop` prompt
names by run ID/PR number. When diagnosing a red the prompt DID ask about
(e.g. "diagnose main's red X") turns up an adjacent finding — keep reporting
that finding, it's inside the named task, not a sweep. Drop it the moment
the prompt is rewritten to exclude it. When the prompt itself changes scope
(a PR merges, a chain finishes), rewrite the `/loop` prompt on the next
`ScheduleWakeup` rather than silently keep tracking the old target.
