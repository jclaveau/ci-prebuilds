---
name: project_wk_perfgate_libm_fmod_breach
description: 2026-09-24 perf-gate-webkit red on ONE row, libm_fmod 1.044-1.052 vs the 1.03 tight ceiling, ratchet 1.000 — RESOLVED 2026-09-25 as an instrument fault, not a regression: WebKit clamps performance.now() to 1 ms, so all SIX in-page probe rows come back as whole integers and the ceiling fell between two reachable ratios; fixed by sizing the kernel 9M to 36M and by making the gate print the observed clock tick per row
metadata:
  type: project
---

Reproduce a failed gate locally — `tally.py`'s `gate_rows()` filters on
`conclusion == "success"`, so a red gate is invisible in the tally:

```sh
gh run download <run> -n perf-gate-webkit -D pgw -R jclaveau/ci-prebuilds
python3 playwright/bench/assert-perf-gate.py pgw --browser webkit --runs 5
```

**The breach was the clock, not the build.** Only **3 `perf-gate-webkit` runs
exist ever** (the row shipped 09-08, `25c9f16`; every other job on record is
`skipped` — it runs only when webkit is actually rebuilt). 2 of 3 breached,
all three on EPYC 9V74:

| date | run | branch/sha | fmod vs official | verdict |
|---|---|---|---|---|
| 09-23 | 35848464161 | main `799bdf7` | 1.022 | ok |
| 09-24 | 35972784207 | main `d2f0ff9` | 1.044 | BREACH |
| 09-24 | 36048405627 | perf/wk-pgo `95f8ef7` | 1.052 | BREACH |

Ratchet across all three: 0.979/1.000/1.000/1.003 — nothing ever regressed.
Geomean 0.912 with every page-driving row a big win.

**Root cause: WebKit clamps `performance.now()` to 1 ms** (JSC timing-attack
mitigation; chromium grants 5 us, firefox also 1 ms but the probe never hits
its floor). `runtime-probe.cjs` times rows two ways, and the split is exactly
visible in the raw medians: rows timed from node (`process.hrtime.bigint()`,
`:52` — launch, context_page, goto_*, locator_click, click_force, screenshot)
carry decimals; the **six** rows timed in-page with `performance.now()`
(eval_rtt, layout, dom_churn, js_alloc, int_math, libm_fmod) are whole
integers. At 62 ms one tick is 1.6-2.2%, so the reachable ratios step 1.000,
1.022, 1.044 — the 1.03 ceiling sits BETWEEN two of them and the row could
only read clean or overshoot by 2x.

**The cv trap, which is the transferable part.** `libm_fmod` read cv
0.008-0.012 — among the lowest on the board — *because every shot repeats the
same integer*. Quantization masquerades as precision, and `perf-gate-margins.json`
says to size a margin from the printed CVs. The margins were seeded on
**chromium** (`_comment`: "same-runner repeats, chromium perf-probe.yml"),
i.e. on a clock 200x finer, then applied to webkit. A CV alone cannot tell the
two apart; nothing in the summary could have.

**FIXED 2026-09-25, straight to main:**

- `runtime-probe.cjs` — libm_fmod 9M to **36M** iterations (~250 ms, one tick
  under 0.5%), plus a **SIZING RULE** comment over the whole `KERNELS` block:
  size every in-page kernel so 1 ms is under ~0.5% of it.
- `assert-perf-gate.py` — a **`tick` column** per row: `observed_tick()` takes
  the float-GCD of every shot in both arms (floored at the 0.001 grid
  `toFixed(3)` writes on) and divides by the reference median. Rows whose
  margin spans fewer than 2 ticks get a warning marker and a named section.
  **Advisory — it does not change the exit code**, because the point is that a
  quantized row's verdict is evidence neither way.
- `tests/bench/test-assert-perf-gate.py` + `tests-perf-gate.yml` — the gate's
  **first test file**; it had zero coverage while gating every browser build.

Replayed against run 36048405627's real artifact, `libm_fmod` is the only
flagged row (2.22%, margin spans 1.3 ticks); int_math 0.6% and js_alloc 0.9%
stay clean at the same 0.03.

**How to apply:** `libm_fmod` is also a **control** in `perf-budgets.json`
`_invalid_cell.controls` alongside `int_math` — re-verify the pair still
agrees on the first run after the resize. Raw `libm_fmod` milliseconds before
and after 2026-09-25 are **not comparable on any browser** (~4x), ratios are.
The webkit `loose` ruling (eval_rtt 0.010-0.024, click_force 0.016-0.047
against a 1.10 ceiling) is still open and still rests on one CPU's worth of
draws. Related: [[project_wk_fastfmod_ships]],
[[project_ff_perfgate_js_alloc_screenshot_breach]],
[[project_perf_gate_ratchet_and_parity]],
[[project_perf_probe_ratio_is_cpu_dependent]].
