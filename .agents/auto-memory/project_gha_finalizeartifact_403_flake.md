---
name: project_gha_finalizeartifact_403_flake
description: a main run can go red on promote jobs with `Failed to FinalizeArtifact … (403) Forbidden` after the image pushes already succeeded — GH artifact-service flake, tags promoted fine, only the aggregate-tags record missed; dispositioned no-action
metadata:
  type: project
---

Seen 2026-09-21, 19:31 Paris run (PR #290 merge): 2 promote jobs went red
with `Failed to FinalizeArtifact … (403) Forbidden` from GH's artifact
service, discovered the next day while triaging an unrelated PR. The image
pushes themselves had already succeeded before the artifact-finalize call
failed — tags were promoted correctly; only the aggregate-tags summary
record was missing.

**Disposition: no action.** Don't re-run the job or chase it as a promote-gate
bug; confirm the tags landed (`gh api` on the registry or the promote job's
own push step logs) before assuming a real failure.

Same session also saw a GH-wide runner queue stall (~16 min, only 5 jobs
in_progress repo-wide against dozens queued) unrelated to this repo's own
concurrency groups — a GH-side capacity issue, not a signal to investigate
locally.
