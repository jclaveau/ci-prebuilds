---
name: conformance-control-leg-test-time
description: Every conformance run times our browser AND the official glibc one in the same run — a free normalized test-time series, and the recipe that showed DCHECKs cost +27% and is_official_build costs nothing
metadata:
  type: project
---

`conformance-chromium-headless-shell-from-source` (ours) and
`conformance-ubuntu-chromium` (official glibc reference) run **in the same run,
same runner pool, same 20-shard suite**. Their ratio is the project's test-time
metric, and it exists retroactively for every run — job timings outlive logs.

Recipe: `gh api .../runs/<id>/jobs --paginate`, group by the part of `.name`
before ` / `, diff `started_at`→`completed_at`, sum and take the median.

Measured:

```
07-29  550b2778  ours 59.8m  ubuntu 47.1m  1.27x   DCHECKs on
08-06  d8860e48  ours 60.1m  ubuntu 47.4m  1.27x   DCHECKs on
08-12  3e713ce   ours 53.0m  ubuntu 48.0m  1.10x   DCHECKs off
08-12  765edbf   ours 52.1m  ubuntu 47.5m  1.10x   DCHECKs off + is_official_build
```

**The DCHECK fix cut the penalty +27% → +10%** (~8 min off a 20-shard run),
reproducible across two before- and two after-runs. **`is_official_build=true`
bought nothing on test time** — its win is size (101.8 → 85.8 MiB compressed)
and the isolated screenshot/layout kernels. Residual +10% vs official glibc is
what PGO/LTO are being measured against ([[project_chromium_gn_perf_knobs]]).

**How to apply:** never compare raw minutes across runs — runner CPU varies per
job and swamps a 10% effect. Divide by the control leg measured beside it. Same
reason the runtime probe puts every target in one job
([[project_runtime_perf_probe]]).

Related: [[feedback_existing_ci_may_already_measure_it]], [[project_alpine_browser_perf_vs_glibc]].
