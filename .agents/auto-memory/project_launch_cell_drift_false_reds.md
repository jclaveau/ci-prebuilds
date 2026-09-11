---
name: project_launch_cell_drift_false_reds
description: the `launch` row drifts on its own — three false reds in one day (2.71x, 5.62x/3.50x, an A/B pair at 3.27x) with int_math/libm_fmod flat, so the invalid-cell gate (which keys on the compute controls) cannot see it; only a FULL rerun clears it, never a report-only rerun, and the image is the same bytes both times
metadata:
  type: project
---

**`launch` is the one perf-probe row whose drift the compute controls do not
witness.** 2026-09-11, `Test and Publish` on PRs touching nothing in any image:

| where | launch read | controls | image identical? |
|---|---|---|---|
| PR #217 first run | alpine 2.71x (4/4 samples 222-311 ms vs 125-137 on main, same CPU) | 1.00 / 1.00 | yes — same `chs-1234@5b768df`, same Dockerfile |
| PR #220 first run | alpine 5.62x AND ubuntu 3.50x | flat | yes |
| chs-perf-ab 34619834664 | 3.27x n.s., samples 218-747 ms | 1.02 / 1.02 | yes (both artifacts remeasured clean elsewhere) |
| PR #214 first run | `eval_rtt` ubuntu 1.46x, samples 182/165/261 | 1.01 / 1.00 | yes |

Every one went green on a full rerun. The pattern: process startup (exec,
loader, zygote fork) and IPC round trips drift with the runner's I/O and
scheduling state, while `int_math`/`libm_fmod` are in-page compute that a
noisy host barely touches. `_invalid_cell` in `perf-budgets.json` keys on
those two controls by design, so a drifted launch cell reads as a genuine
breach.

**How to apply:**
- A red `launch`/`eval_rtt` cell on a PR that ships no image bytes is a
  rerun, not a finding. Confirm first: `gh pr diff --name-only` has no
  Dockerfile/image input, and the build job pulled the same `chs-<rev>@sha`
  as main's last green (grep the build-playwright-dood log for `chs-`).
- `gh run rerun --failed` re-runs only `perf-report`, which re-asserts the
  SAME artifact and fails again; it must be `gh run rerun <id>` (full), and
  the queued partial rerun has to be cancelled first or the full one queues
  behind it.
- Read launch samples, not the median: four samples all 2-5x is drift; one
  sample at 530 ms among three at 100 is a single hiccup the median absorbs.
- If this keeps costing reruns, the fix is a launch-specific sanity in
  `assert-perf-budgets.py` (official's own launch against its band, or a
  spread test on the samples), not a wider budget. Parked, not built.
