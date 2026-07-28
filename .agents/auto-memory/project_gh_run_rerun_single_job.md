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

Related: [[project_multijob_base_image_audit]].
