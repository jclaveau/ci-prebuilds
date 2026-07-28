---
name: project_multijob_base_image_audit
description: When adding a round to the chromium-from-source multi-JOB pipeline, audit ALL BASE_IMAGE build-args downstream — the finalize job's BASE_IMAGE was silently stale for 4 iterations (r4-r7 rounds unused)
metadata:
  type: project
---

The chromium-from-source producer chains `Dockerfile.setup → Dockerfile.round (× N) → Dockerfile.finalize`. Each stage reads `BASE_IMAGE` from a build-arg pointing at the prior stage's tag: `chs-build-setup-sha-*` → `chs-build-r1-sha-*` → ... → `chs-build-rN-sha-*`.

**Why:** During v18/v19/v20 iterations, I added r4, r5, r6, r7 rounds to buy more compile budget, but forgot to update the finalize job's BASE_IMAGE from the initial `chs-build-r3-sha-` to the new last-round tag. All four rounds pushed successfully but finalize kept reading from r3's 16193 .o baseline, effectively discarding ~12000 .o that r4-r7 painstakingly produced. Discovered only when v19's finalize died at ninja step 13152/15531 — should have been at ~28000/... with the r7 baseline. Fix landed in bcb1f79.

**How to apply:** Any commit that adds/removes a round to `.github/workflows/playwright-alpine-browsers.yml`:
1. `grep -n 'BASE_IMAGE' .github/workflows/playwright-alpine-browsers.yml` — inventory ALL references
2. Confirm the last-round tag matches the new `needs:` chain terminator
3. In particular: `build-chromium-headless-shell-from-source` job's build-args `BASE_IMAGE=...chs-build-r<LAST>-sha-...` must point to the FINAL round, not the initial one

Signal it went wrong: rounds succeed, finalize runs "as if" it started from an earlier obj/ state (progress numbers don't match round outputs).

Related: [[project_buildkit_cacheto_commit_semantics]].
