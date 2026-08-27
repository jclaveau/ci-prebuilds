---
name: parked_chromium_promote_and_pgo_comment
description: three items parked 2026-08-21 while the chromium perf comparison takes priority — chs-latest retag, the any-branch promote gate, and the args.gn PGO comment
metadata:
  type: project
---

Parked at the user's instruction ("park your 3 points") on 2026-08-21 so the
PGO/ThinLTO bench comparison could go first. None are resolved.

1. **`chs-latest` points at an experiment.** The two perf arms each promoted on
   completion and overwrote it within 8 minutes: PGO `a649cb7` at 13:40:05, then
   ThinLTO `b689c01` at 13:47:51 — displacing the main-lineage `911c93b`
   (from-source, built 02:49). Both passed conformance 20/20 + smoke, so nothing
   is broken, but neither config is adopted. Fix is a `docker buildx imagetools
   create` retag to `911c93b`, no rebuild. Pinned `chs-<rev>` tags unaffected.

2. **The promote gate is branch-blind — RESOLVED 2026-08-27, PR #128.**
   `promote-chromium-from-source.yml` had NO `github.ref` check anywhere and is
   dispatch-only, so any green dispatch from any branch retagged `chs-<rev>`,
   `chs-<version>` and `chs-latest` on BOTH registries. Now guarded on
   `refs/heads/main`. The guard **fails** rather than skipping, unlike the
   webkit promote's job-level `if:`: a skipped job reports the run green, and a
   promote workflow that says green without promoting is the shape that already
   cost this repo a wrong conclusion once ([[project_resume_from_runs_only_r1]]).
   See [[project_promote_gates_by_browser]].

3. **`args.gn.overlay` PGO comment is now stale.** Line 151
   `chrome_pgo_phase = 0  # no PGO (build wall-clock); aports same`, plus the
   header at 13–16 claiming official "buys the optimization level WITHOUT the
   PGO/LTO build cost". The PGO arm built fine and needs no depot_tools (public
   83 MB profile + `pgo_data_path`), so build wall-clock is the only surviving
   justification. See [[project_chromium_gn_perf_knobs]]. Not applied: it was a
   note I left myself, never the user's decision.

**How to apply:** raise 1 and 2 together once the bench verdict is in — the
verdict may make the right `chs-latest` target something other than `911c93b`.
