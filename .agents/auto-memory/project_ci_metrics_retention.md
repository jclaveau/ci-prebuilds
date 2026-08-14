---
name: ci-metrics-retention
description: What GitHub keeps vs drops for this repo's CI history — metadata complete since day one, logs 90 days, artifacts per-upload, GHCR sizes never recorded; measured 2026-08-14
metadata:
  type: project
---

Measured 2026-08-14, for the "CI cost / image size / test time since project
start" graph:

| layer | horizon | note |
|---|---|---|
| run + job metadata | **complete**, 2110 runs back to 2025-10-17 (repo creation) | not expiring; this is where minutes and per-shard test time live |
| run **logs** | **90 days** | `2026-05-28` served, `2025-10-21` → **410 Gone**. Everything log-derived (ninja counters, test tallies, bench tables) is already lost before ~2026-05-16 and rolls off daily |
| artifacts | per-upload `retention-days` (we use 14 / 30 / default 90) | 15068 exist today |
| GHCR versions | kept with `created_at` + tags (1399 on `alpine-dood-playwright`) | **no size field, ever** |

**Two conclusions that shape any collector:**

- **Cost is runner-minutes, not dollars.** `/actions/runs/<id>/timing` returns
  `billable: 0` — public repo, free minutes. A money axis can only be a
  labelled counterfactual (`minutes × rate`).
- **The image-size series cannot be reconstructed, at all.** Sizes exist only
  inside manifests, and old digests get pruned. Un-sampled history is gone;
  sampling has to start before it can ever exist.

**How to apply:** salvage is narrow and urgent — extract *numbers* out of logs
inside the 90-day window and stop treating raw logs as the store (tens of GB,
`/home` at 90%). Metadata backfill is cheap and can wait. Normalize test time by
the in-run control leg ([[feedback_existing_ci_may_already_measure_it]]), and
dedupe by `run_attempt` or `rerun --failed` double-counts.

Draft collector parked at `scripts/collect-metrics.py`, uncommitted — jean asked
for insight first and had not yet chosen storage location, backfill depth, or
cadence.
