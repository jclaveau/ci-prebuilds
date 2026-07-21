---
name: project-gha-api-stale-during-long-builds
description: GHA REST API (gh run view) lags 1-3h behind actual job state during multi-hour webkit/firefox builds; trust elapsed-clock not API status
metadata:
  type: project
---

During webkit producer runs (8-12h cycles), `gh run view --json status,jobs` consistently reports `in_progress` for jobs that have actually completed up to **1-3 hours earlier**. The discrepancy isn't a one-off — observed across iter #4 through iter #13 of the smoke-fix push series.

Examples seen:
- `gtk-2` reports `in_progress` at clock-elapsed 6h+ — past GHA's 6h hosted runner hard-kill — yet `completedAt` updates 30+ min later to a 4h-ish duration.
- `wpe-2` reports `in_progress` for 2h after `wpe-3`/`wpe-4` (downstream `needs:`-dependent jobs) already show `success`. Downstream conclusions are reliable; the in_progress upstream is the stale view.
- Step-level `gh run view --log --job <id>` returns empty body until the job finalizes, even when downstream jobs depend on its outputs.
- The raw REST job-logs endpoint (`curl .../actions/jobs/<id>/logs`) returns a **216-byte Azure `<Error><Code>BlobNotFound</Code>` XML** (not stale text, not empty) for an in-progress webkit build — the log blob isn't published until finalize. Seen on wpe-2/gtk-2 for ~2h. Don't parse it as content; it means "still running, can't read progress" → fall back to elapsed-clock + downstream conclusions.

**Why:** GHA's job-completion event ingestion is decoupled from the run state in the REST view. The web UI updates faster (~minutes) than the API. Webhook-driven workflows (`workflow_call`, downstream `needs:`) see the real conclusion first.

**How to apply:** when polling a long-running webkit/firefox build, infer real state from two signals, not the headline:
- **Downstream conclusion overrides upstream in_progress.** If wpe-3 reports `success` while wpe-2 reports `in_progress`, treat wpe-2 as done.
- **Clock-elapsed vs typical duration.** If wpe-1 typically takes 4h 33m (4.5h SIGTERM budget) and clock says 5h 30m, it's done; API is just slow.
- Set wakeup cadence based on clock, not API state. After GHA's 6h hard-kill, wakeup short (5-10min) — API will catch up imminently.

Don't wait for the API to clear `in_progress` before scheduling the next short poll — adds hours of cumulative idle when the run is actually mostly done.

Related: [[project-webkit-alpine-branch-c]] (the long builds where this matters), [[feedback-wakeup-cadence-by-job-type]] (cross-project wakeup heuristic).
