---
name: project_gh_run_rerun_single_job
description: `gh run rerun --job N` restarts a single failed job while preserving upstream job outputs — saved 2h04m of chromium-from-source r1 wall-clock when r2 hit a transient buildkit failure
metadata:
  type: project
---

`gh run rerun --job <job_id>` re-runs a single failed job in-place, keeping the run's other jobs and their outputs intact. Downstream `needs:`-gated jobs then spawn from the successful rerun.

**Why:** During v26 (28798487911), r2 died 10 min in with a BlobNotFound registry glitch. r1 had already taken 2h04m to produce `chs-build-r1-sha-a792691...`. Full re-dispatch would have redone r1 = wasted 2h. `gh run rerun --job 85428661100` restarted r2 alone — it pulled r1's tag from ghcr (still fresh), completed in 17m37s, r3-r8+finalize cascaded normally.

**How to apply:** When a chromium-from-source job fails transiently (registry hiccup, network flake, workflow_run partial retry):
1. Verify the upstream job's output tag exists: `docker manifest inspect ghcr.io/.../chs-build-r<N-1>-sha-<sha>`
2. `gh run rerun --job <failed_job_id>` (get id from `gh run view <run> --json jobs -q '.jobs[]|select(.name=="...")|.id'`)
3. Watch normally — chain resumes from the re-run job

Do NOT use for real failures (compile errors, dep issues) — those need a code fix + fresh dispatch.

**Exception: `perf-report` does not re-measure.** 2026-09-23, PR #303's
`perf-report` job failed on `webkit/alpine js_alloc 1.55x exceeds its 1.40x
budget`. Rerunning just that job (`gh run rerun --job`) re-asserted the exact
same 1.55x and failed identically — `perf-report` only `download-artifact`s
the prior `perf-probe` job's output and asserts against it; it never re-runs
the probe. Confirmed a draw outlier (not a regression) by triggering a **full
rerun of the whole run** (`gh run rerun <run_id>`, no `--job`), which redrew
`perf-probe` and came back inside budget. For any job that consumes a
sibling's `download-artifact` output rather than producing its own
measurement, a single-job rerun replays the stale input — check the job's
`needs:`/`download-artifact` before assuming a rerun redraws anything.

**Confirmed the other direction, 2026-09-24: `perf-gate-firefox` DOES
redraw.** Its step 6 (`Probe every arm, 5x each, interleaved`) runs the probe
in-job and contains zero `download-artifact` calls, unlike `perf-report`
above. A single-job rerun of it (`gh run rerun --job <id>`) produced a
genuinely independent second draw for [[project_ff_pgo_corpus_append_experiment]]
— confirmed by checking the job's steps before rerunning, same method as the
`perf-report` case, opposite result. Always check per-job, not per-workflow.

Related: [[project_multijob_base_image_audit]].
