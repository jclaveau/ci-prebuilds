---
name: chromium_round_images_sha_keyed
description: chromium round images are tagged by github.sha, so any setup-layer edit forces a full cold r1..r12 rebuild
metadata:
  type: project
---

Every round pushes `chs-build-rN-sha-${{ github.sha }}`, and each round's
`BASE_IMAGE` is the previous round at the **same** sha. So a new commit gives
the whole chain new tags and nothing from the previous chain is reused unless
`resume_from` points r1 at an old image (see [[resume_from_runs_only_r1]]).

Consequence: **editing `Dockerfile.setup` or `apply-and-build.sh` invalidates the
setup layer and costs a full cold chain.** Editing a script that
`Dockerfile.finalize` re-COPYs (`ninja-resume.sh`, `stage-cache-layout.sh`) is
cheap by comparison — that asymmetry is what
[[project_finalize_overlay_baked_scripts]] is about, seen from the cost side.

Cold cost, measured 2026-08-19 on chromium 151 (`is_official_build=true`, LTO
and PGO both off): setup 25m, then r1 hit the `timeout 18000 ninja` box at
5h12m having built **7578 of 38707** targets — ~1500 targets/hour. Budget
**25-30h** for the chain, not the ~13h that [[project_chromium_from_source_split_build]]
records for chromium-148. sccache does not rescue it: hit rate was 1.37% on r1
and 0.77% on r2 of the previous chain, and the mount is BuildKit-local so it
never crosses runners.

**How to apply:** when a fix must land in setup, say the cold-rebuild cost out
loud before choosing where it goes, and offer the finalize-layer stopgap with a
TODO as the cheap arm.

**Corrected 2026-08-21 — cold cost is 40-45h, not 25-30h.** The 25-30h figure was
extrapolated from r1 and never checked against a finished run. Completed cold
from-source runs: `main` 40.0h (8 rounds), `perf/chromium-official-build` 41.1h,
`perf/chromium-thinlto` 42.2h (12 rounds), `perf/chromium-pgo` 45.3h (12 rounds).
Baseline run 32262979614 took **36h50** (setup 24m + r1..r7 boxed at 5h11 each +
r8..r12 at 15-20m + finalize 18m).

Shape to expect: every early round consumes the whole 5h12 box and edge counts
flatten (18309, then 7521, then ~2000 per round) while the link tail clears —
then the last rounds collapse to minutes. **Do not extrapolate an ETA from edge
counts**; that curve predicts non-convergence. Calibrate against a finished run
of the same arm instead (`gh run list` + duration filter).
