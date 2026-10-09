---
name: project_ff_perfgate_js_alloc_screenshot_breach
description: RESOLVED 2026-09-24 — the red perf-gate-firefox run (35848449972) was stale, pre-PGO; the very next main gate draw after PR #285/04dde38 (PGO) landed reads js_alloc 0.981 and screenshot 0.896, both PASS — no separate js_alloc bug existed, PGO fixed it as a side effect
metadata:
  type: project
---

2026-09-24, `perf-gate-firefox` red on main (799bdf79, run 35848449972,
20h+ stale by the time it was looked at).

| row | ratio | ceiling | verdict |
|---|---:|---:|---|
| js_alloc | 1.065 | 1.03 | ❌ |
| screenshot | 1.077 | 1.03 | ❌ |
| dom_churn | 0.740 | 1.06 | ✅ |
| libm_fmod | 0.563 | 1.03 | ✅ |
| **geomean** | **0.919** | 1.02 | ✅ |

This is [[project_perf_gate_ratchet_and_parity]]'s per-row ceiling working
as designed, not a flake: geomean passing comfortably does not exempt an
individual row from its own ceiling.

**Ruled out runner noise before treating either row as real:** the
same-job reference arm (`fi-latest` vs official, [[project_perfgate_reference_arm_noise]]'s
check — diff the reference numbers across runs before touching the
candidate) reads clean at geomean 0.993, `js_alloc` 0.994, `screenshot`
0.996. So this candidate specifically regresses those two rows while
winning everywhere else; it isn't a bad reference draw.

- `screenshot` 1.077 matches the already-open, already-diagnosed
  [[project_ff_png_encoder_gap]] item (libpng+zlib must ship as a pair;
  the runtime-probe screenshot row held at 0.68x→0.69x even after the
  encoder bytes reached parity — capture/readback, not encode).
- `js_alloc` 1.065 was flagged **new and unexplained** at first reading.

**Resolved, not a separate bug:** the red run (799bdf79, 09-23 10:22) was
20h+ stale by the time it was looked at, and predates [[project_ff_pgo_arm_mechanics]]
(PR #285, merged as `04dde38`). The very next main perf-gate draw
(job 107321907380, post-PGO) reads `js_alloc 0.981`, `screenshot 0.896`,
geomean 0.767, **PASS** — both rows moved because PGO landed in between,
not because either row got its own fix. `js_alloc` never needed its own
instrument; it was riding the same build-epoch jump as every other row
(see [[project_ff_pgo_arm_mechanics]]).

**How to apply:** before chasing a single red perf-gate run as a live bug,
check the run's age/head_sha against the browser's latest merged perf PR —
a gate reading a pre-PGO (or generally pre-perf-landing) commit will show
regressions that are already fixed on main. Confirmed method: diff the
next gate draw on the same row before instrumenting anything.
