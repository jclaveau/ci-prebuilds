---
name: project_bench_execution_index
description: The bench's Δ execution % column — median of raw ms across runs (no normalizer), MIN_RUNS=5, locator_click excluded; it reports alpine chromium ~16% slower than official, carried by layout 1.60x and launch 1.48x
metadata:
  type: project
---

`benchmark-playwright.yml` measured only what a consumer pays to REACH a running
test. `Δ execution %` (PR #120) adds how fast the browser then executes, from
`playwright/bench/runtime-probe.cjs` run in every hosted scenario. `Test run`
could not stand in for it — both its tests fetch `https://playwright.dev/`, so
that column is mostly internet.

Logic lives in `scripts/exec_index.py`, tested by
`tests/conformance/test-exec-index.py`.

**The measurement, on 10 runs (33038504763):** alpine-dood chromium is
**+16% (gsd 16%)** against official, matching a same-CPU ground truth of +16%.
Per metric: `layout` **1.60x**, `launch` **1.48x**, `goto_warm` 1.30, `goto_cold`
1.21, `click_force` 1.14, everything else 1.00-1.11. Consistent with the residual
in [[project_chromium_residual_gap_candidates]] — the bench now sees it on every
run instead of needing a dedicated A/B.

**Design, and what was tried and removed:**

- The index is the geometric mean of each metric's MEDIAN across runs. An
  earlier version divided every metric by that run's `int_math` to cancel the
  runner's CPU; measured against ground truth it changed nothing (0.0083 vs
  0.0085 mean |log err|) and on alpine ANTI-correlated with the kernels it stood
  in for. Deleted. [[feedback_prove_the_lever_is_connected]]
- `MIN_RUNS = 5`, enforced — below it the column reads `—`. Subsampling put n=3
  at sd 6.6% with a worst draw of +40.8%.
  [[feedback_subsample_to_find_the_sample_size]]
- `locator_click` excluded: 3333.x ms both sides, CV 0.0%, frame-quantized.
  Metrics at ~1.000x are NOT excluded — parity is a finding.
- `KEEP_LIBC_METRICS` toggles `libm_fmod`, which is a C-library kernel rather
  than a browser one and where musl runs ~1.7x FASTER on firefox.

**Open:** the hosted tables' reference is `vm + manual install`, right for
install cost and odd for execution; and the rendered `gsd N%` should be a
multiplicative band, not a percent ([[feedback_bench_geomean_normalize]]).
The act tables have no probe.
