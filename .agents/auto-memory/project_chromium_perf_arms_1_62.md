---
name: chromium_perf_arms_1_62
description: VERDICT 2026-08-21 — ThinLTO wins on layout (0.62x baseline), PGO trails at 0.71x; both cost +10% build; the two routes to thinlto-vs-pgo agree
metadata:
  type: project
---

`perf/chromium-thinlto-1.62` (`b689c01`) and `perf/chromium-pgo-1.62`
(`a649cb7`) branch off `feat/pw-1.62.1-sweep` @ `7ba6866` and each differ from
it by **one variable**: `use_thin_lto = true` / `chrome_pgo_phase = 2` plus the
`pgo_data_path` plumbing.

**VERDICT, measured 2026-08-21.** Both arms completed, both green (conformance
20/20 + smoke), and `chs-perf-ab.yml` paired each against a baseline
(`chs-fs-sha-911c93b`) on ONE runner per run. Ratios are candidate/baseline, so
below 1.0 is faster; **bold** = delta exceeded the samples' own spread.

| metric | PGO | ThinLTO | thinlto vs pgo (head-to-head) |
|---|---|---|---|
| layout | **0.71x** | **0.62x** | **0.89x** |
| dom_churn | **0.81x** | 0.89x n.s. | 0.89x n.s. |
| js_alloc | **0.84x** | 1.00x n.s. | **1.04x** |
| click_force | 0.95x n.s. | **0.93x** | 0.97x n.s. |
| eval_rtt | 0.97x n.s. | **0.92x** | 1.00x n.s. |

- **ThinLTO is the pick.** Layout is the largest effect anywhere in the data and
  the only row significant in all three runs. It is also on the critical path of
  most interactions.
- The two independent routes agree: 0.62/0.71 implies thinlto/pgo = **0.87**,
  and the direct head-to-head measured **0.89**. That cross-check is the reason
  to trust an 11% layout gap that no single run could establish alone.
- **Build cost is not a discriminator**: baseline 36.8 h, PGO 40.5 h, ThinLTO
  40.6 h — about +10%, ~4 h on a ~37 h build. The `args.gn.overlay` comment's
  "without the PGO/LTO build cost" overstates what was avoided.
- **Never compare absolute ms across runs.** The head-to-head runner was ~2x
  faster than the baseline runners (pgo layout 24.1 ms there vs 52.1 ms;
  screenshot 333.7 vs 501.3). Only the within-run ratio is portable.
- Controls behaving: `libm_fmod` and `int_math` sit at 1.00x (musl libm cannot
  be moved by gn flags), `locator_click` at 3333 ms everywhere (frame-bound).
  Their "significance" flags are tight-sample artifacts, not findings.
- **Untested: both knobs together.** `is_official_build` would default both ON;
  each arm changed exactly one. A combined arm is another ~40 h build.

**Do not rebase the older `perf/chromium-{thinlto,pgo,official-build}`
branches.** They sit on a main from before the metrics tree, the gap probes and
six memories — `git diff main..` is ~113k deletions — and they predate the
dawn/Go fix, so they compile ~25h and then die at finalize.

Facts measured 2026-08-19 that contradict the older comments:
- The PGO profile **ships inside the chromium tarball** (`PGO profile already in
  the tree`), so the fetch path is a fallback that has never run.
- It is **296 MB** for chromium 151, not the ~83 MB the ported comment claims.
- It is a compiler input only — `.profdata` is consumed via `-fprofile-instr-use`
  and cannot reach the artifact, which is `FROM scratch` + one `COPY`.
- `is_official_build` does NOT imply LTO/PGO here: the overlay pins
  `use_thin_lto = false`, `chrome_pgo_phase = 0`, `is_cfi = false` explicitly.
  Reading the gn *default* and ignoring those three lines is how I mis-blamed a
  5h round on ThinLTO.

**How to apply:** verify each arm's resolved `args.gn` in its own setup log
before reading any number off it ([[feedback_verify_ab_varied_the_variable]]).
Different refs also mean different concurrency groups and different
`chs-build-rN-sha-*` tags, which is what lets the arms run in parallel
([[project_gha_concurrency_group_serializes_dispatches]], [[chromium_round_images_sha_keyed]]).
