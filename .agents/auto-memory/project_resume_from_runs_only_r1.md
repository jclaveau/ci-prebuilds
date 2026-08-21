---
name: resume_from_runs_only_r1
description: chromium from-source resume_from skips setup, which poisons r2..finalize and the run reports SUCCESS having built nothing
metadata:
  type: project
---

`workflow_dispatch` with `resume_from` set makes
`build-chromium-headless-shell-from-source-setup` skip. Only **r1** tolerates
that — its `if:` carries `!cancelled() && (setup.result == 'success' ||
setup.result == 'skipped')`. `r2`..`r12`, finalize, smoke, conformance and
promote have a plain `if:` with no status function, so GHA's implicit
`success()` fails on the skipped ancestor and every one of them skips.

Skipped counts as success, so **the run concludes `completed/success` having
compiled nothing past r1**.

**Why:** run 32256708703 (2026-08-19) resumed from the previous chain's r12,
ran r1 for 15m21s, skipped everything after it, and reported green. The dawn/Go
fix it was dispatched to test never executed. Cost a full dispatch cycle and
nearly shipped a "verified" claim on a build that never ran.

**How to apply:** before trusting ANY green from a `resume_from` dispatch, list
the jobs and confirm finalize actually ran — not just the run conclusion. Fixing
it means giving r2..finalize the same tolerance r1 has (13 job conditions, one
file). Same family as [[feedback_gha_skipped_chain_not_cancelled_guard]] and
[[reference_gha_required_check_mechanics]] (skipped == success).
