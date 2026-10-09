---
name: project_perfgate_reference_arm_noise
description: A perf-gate breach on a non-launch row can come from the official or promoted arm drawing a noisy reference, not the candidate — arbitrate by comparing raw per-shot numbers across two gate runs that drew the same runner CPU
metadata:
  type: project
---

`project_launch_cell_drift_false_reds` already covers `launch`/`eval_rtt`
drifting with runner I/O. This is the same shape on other rows, caught
differently: instead of one run's samples looking wild, TWO perf-gate runs
that happened to draw the **same runner CPU** disagree on the reference
arm's own number for the same row.

2026-09-23, two chromium candidates gated back-to-back, both on EPYC 7763:
fortify header-variant (`31da628`, run 35841462423) and textstack (`6e56156`,
run 35844059924). Comparing their raw per-shot tables:

- **`screenshot` breach (fortify, ratchet 1.070 ❌) — noise on the
  *promoted* arm.** Candidate and official both saturated tight at ~500 ms
  in both runs; only fortify's `promoted` arm scattered
  `[500.7, 399.9, 483.4, 467.2, 433.0]` (median 467.2) while textstack's
  `promoted` read a flat 499.9. Same promoted image, same runner class, one
  run's samples fell apart — a broken draw on the reference, not a candidate
  regression.
- **`goto_warm` breach (fortify, parity 1.068 ❌) — noise on the *official*
  arm.** Fortify's official read 194.7 ms; textstack's official (same
  runner class, same day) read 204.6 — a 5% swing on the reference alone.
  Fortify's own candidate was stable across both runs (207.9 / 212.0). Read
  against textstack's official instead, fortify's ratio would be 1.017, not
  1.068.
- **`layout` breach (textstack, parity 1.031 ❌) — RETRACTED, was also a
  draw artifact.** Called "real" here off tight per-shot spread on one
  7763 draw. A second textstack draw landed on a different runner
  (`EPYC 9V45`) and read `layout` **0.994** (pass) — the breach did not
  survive an independent draw either, same as the other two. Tight CV within
  one draw rules out a *broken shot*, not a *runner-dependent* row.
  Full correction, including the fortify/textstack stacking relationship
  this file's framing got wrong, in
  [[project_chromium_fortify_textstack_draw_lottery]].

**How to apply:** when a perf-gate run breaches and a second gate run from
the same day/runner-CPU exists, diff the two runs' **official and promoted**
arm numbers for the breaching row before touching the candidate at all — a
reference arm that moved 3-5% between two runs on the same silicon is the
tell, cheaper than a rerun. Only trust a breach once the reference arms
agree across runs (or the candidate itself has tight per-shot spread and no
comparison run exists).
