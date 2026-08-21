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

2. **The promote gate is branch-blind.** `chromium-from-source` promotes
   `chs-latest` from ANY branch on a green dispatch, unlike firefox's
   main-gated promote — that asymmetry is what let (1) happen, and it will
   recur on the next perf dispatch. See [[project_promote_gates_by_browser]].

3. **`args.gn.overlay` PGO comment is now stale.** Line 151
   `chrome_pgo_phase = 0  # no PGO (build wall-clock); aports same`, plus the
   header at 13–16 claiming official "buys the optimization level WITHOUT the
   PGO/LTO build cost". The PGO arm built fine and needs no depot_tools (public
   83 MB profile + `pgo_data_path`), so build wall-clock is the only surviving
   justification. See [[project_chromium_gn_perf_knobs]]. Not applied: it was a
   note I left myself, never the user's decision.

**How to apply:** raise 1 and 2 together once the bench verdict is in — the
verdict may make the right `chs-latest` target something other than `911c93b`.
