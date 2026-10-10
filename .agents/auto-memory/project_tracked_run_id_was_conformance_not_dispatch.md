---
name: project_tracked_run_id_was_conformance_not_dispatch
description: a run id carried across sessions as "the textstack-snap build chain" turned out to be PR #277's ordinary conformance run, not a dispatch of the build — the real chain had never been kicked off
metadata:
  type: project
---

On "go textstack snap?" the run id previously tracked across handoffs for
PR #277's textstack-snap candidate was checked and turned out to be just the
PR's routine conformance run, not a dispatch of the from-source build chain.
The actual chromium-from-source chain for that candidate had never been
started — dispatched cold only at this point (35645764121, ETA ~36-40h).

A run id surviving several session handoffs (in "Pending Tasks" prose) is not
by itself evidence the thing it names was dispatched — a run id is valid on
any workflow in the repo, and PR conformance runs get created automatically
on every push, so a stale note can silently point at the wrong workflow.

**How to apply:** before reporting a long build chain as "in flight" purely
from a carried-over run id, confirm via `gh run view <id>` that its
`workflowName` is the expected build/round workflow, not conformance or TP.
Cheap check, catches a multi-day silent stall.
