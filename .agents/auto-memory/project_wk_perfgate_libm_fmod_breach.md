---
name: project_wk_perfgate_libm_fmod_breach
description: 2026-09-24 perf-gate-webkit red on ONE row, libm_fmod 1.044-1.052 vs the 1.03 tight ceiling, ratchet 1.000 — RESOLVED 2026-09-25 as an instrument fault, not a regression: WebKit clamps performance.now() to 1 ms, so all FIVE in-page probe rows come back as whole integers and the ceiling fell between two reachable ratios; fixed by sizing the kernel 9M to 36M and by making the gate print the observed clock tick per row, and the re-run PASSED at 1.026
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
carry decimals; the **five** rows timed in-page with `performance.now()`
(the `KERNELS` block: layout, dom_churn, js_alloc, int_math, libm_fmod) are
whole integers. `eval_rtt` is NOT one of them despite measuring an in-page
round trip -- `sample()` times it from node like the rest, and the gate's tick
column confirms it at 0.00% across all four runs. At 62 ms one tick is 1.6-2.2%, so the reachable ratios step 1.000,
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
- `assert-perf-gate.py` — a **`tick` column** per row: `observed_tick()` reads
  the coarsest **decimal grid** every shot in both arms sits on (0.001 from
  `toFixed(3)` up to 1 ms, `COARSEST_TICK_MS`) and divides by the reference
  median. Rows whose margin spans fewer than 2 ticks get a warning marker and
  a named section. **Advisory — it does not change the exit code**, because
  the point is that a quantized row's verdict is evidence neither way.
  It first took the float-GCD of the shots instead, which **over-claims**: on
  the very first run `int_math` read 188.0 on all ten shots of both arms, so
  their GCD was 188 and the steadiest row on the board reported a 188 ms clock
  and flagged itself. A GCD over few shots is not a clock; real steps are
  decimal. Fixed same day (Euclid deleted, 6/6 mutants killed).
- `tests/bench/test-assert-perf-gate.py` + `tests-perf-gate.yml` — the gate's
  **first test file**; it had zero coverage while gating every browser build.

Replayed against run 36048405627's real artifact, `libm_fmod` is the only
flagged row (2.22%, margin spans 1.3 ticks); int_math 0.5% and js_alloc 0.9%
stay clean at the same 0.03.

**The fix landed green.** Gate run **36126861080** (2026-09-25, same candidate
`wk-sha-95f8ef7`, EPYC 9V74) **PASSED**: `libm_fmod` parity **1.026** against
the 1.03 ceiling at tick **0.4%**, ratchet 1.007, geomean 0.903 / 0.998, no
row flagged. So the row's real gap vs official is **2.6%, under the bar** —
the old 1.044/1.052 were the rounding artifact, not a regression, and this is
the first measurement of the row that means anything. The `_invalid_cell`
control pair agrees: `int_math` 1.000/1.000 beside `libm_fmod` 1.026/1.007.

**How to apply:** raw `libm_fmod` milliseconds before
and after 2026-09-25 are **not comparable on any browser** (~4x), ratios are.
The webkit `loose` ruling **closed 2026-09-25**: both rows dropped to
`default` 0.06 and `loose` now holds no browser. Four draws (all EPYC 9V74)
measure eval_rtt cv 0.004-0.024 and click_force cv 0.002-0.054, so 1.10 was
4x and 2x their own noise, and the entry traced to perf-budgets.json's n=1
cross-CPU note -- the same provenance defect that retired firefox's. What
settled it: `eval_rtt` is the node<->CDP round trip, identical on all three
arms, so it is a NULL CONTROL that must not be free to swing 9%; while
`click_force` is three-quarters browser work and reads **1.023-1.043 against
official in all four draws** with its ratchet at parity -- a standing gap
1.10 was calling green, matching the musl scalar memset/memcpy finding in
[[project_chromium_click_force_never_profiled]]. All four runs still clear
0.06; `eval_rtt` is a `tight` candidate once a second CPU prices it (worst
draw 1.028, too thin today). Related: [[project_wk_fastfmod_ships]],
[[project_ff_perfgate_js_alloc_screenshot_breach]],
[[project_perf_gate_ratchet_and_parity]],
[[project_perf_probe_ratio_is_cpu_dependent]].
