# metrics/

A local, append-only record of what this project's CI costs and what it buys,
kept because GitHub does not keep most of it.

```sh
pnpm metrics:collect   # snapshot runs, jobs, artifacts, GHCR sizes
pnpm metrics:report    # rebuild report.md + report.png
```

## What is stored

- **`runs/YYYY-MM.jsonl`** — one row per workflow run attempt.
- **`jobs/YYYY-MM.jsonl`** — one row per job, **with its per-step timings**.
  The steps are the point: both benchmark headline numbers come from them and
  from nothing else that outlives 90 days.
  - `time-to-tests` = job start → the test step starts (mostly image pull)
  - `test time` = that step's own duration (what the browser build costs)
- **`images/YYYY-MM.jsonl`** — one row per (package, digest), with every layer's
  `[blob digest, compressed bytes]`.
- **`artifacts/YYYY-MM.jsonl`** — one row per artifact, with `expires_at`.

Files are partitioned by month so a weekly snapshot rewrites only the current
month's blob and every earlier month stays byte-identical in git forever.

The stores are append-only and a row caught mid-flight is re-appended once it
settles, so **readers must take the last row per key** — `load()` in
`scripts/metrics-report.py` does.

## Two different "size" questions

The layer digests exist because *pull size* and *storage occupancy* are not the
same number, and conflating them is off by a factor of three here:

- **Pull size** — sum of a manifest's own layers. What a consumer downloads, so
  shared base layers count in every image. `compressed_bytes` on each row.
- **GHCR occupancy** — union of *distinct* blob digests. The registry stores a
  blob once no matter how many tags point at it. Summing per-manifest totals
  instead turned 80.6 GB of real storage into 207 GB for one package.

## What is already unrecoverable

Measured 2026-08-14; the repo's first run is 2025-10-17.

| source | retention | consequence |
|---|---|---|
| run + job metadata, incl. steps | indefinite | complete back to day one — the backfill takes all 2110 runs |
| run **logs** | 90 days | ninja counters, per-test tallies: only inside the window, rolling off daily |
| artifacts | 14/30/90 days per upload | `expires_at` says what is about to go |
| GHCR sizes | **never recorded** | must be sampled; a deleted version's size is gone |
| GHCR versions | — | oldest surviving version is **2026-05-29**, so nothing before that exists to sample |

`billable` is deliberately not stored: on a public repo every `duration_ms` in
it is 0. Runner-minutes, summed from the job rows, is the real cost unit.
