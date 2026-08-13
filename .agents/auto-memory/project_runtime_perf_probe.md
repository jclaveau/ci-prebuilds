---
name: runtime-perf-probe
description: playwright/bench/runtime-probe.cjs measures how fast the shipped browsers EXECUTE (vs the cold-start bench) — one job per browser so all targets share a runner; locator_click is frame-bound by design
metadata:
  type: project
---

**`playwright/bench/runtime-probe.cjs` + `perf-report.py` + the `perf-probe` /
`perf-report` jobs in TP.** Observe-only (absent from `promote`'s `needs:`,
`continue-on-error`). Complements `benchmark-playwright.yml`, which measures cold
start — nothing measured execution speed, which is why a DCHECK chromium shipped
for months with every test green and only the wall clock moving.

**Two design points that cost a rewrite each:**

- **One job per BROWSER, probing every target inside it.** Hosted runners hand out
  different CPU models per job — EPYC 9V74, Xeon 8370C and Xeon 6973P-C all turned
  up in one run, and chromium's three cells landed on three of them. A control on
  a sibling runner is not a control; the first run produced ubuntu ratios of
  0.62-0.90x that were pure CPU luck.
- **`locator_click` is FRAME-CADENCE bound, not CPU bound.** Healthy builds agree
  across libcs to four significant digits (chromium 3332.9 / 3332.7 ms per 100
  clicks = 2 frames at 60Hz; webkit 3217.1 on all three targets; firefox exactly
  5000). Keep it — a build too slow for its frame budget shows up (the DCHECK one
  sat at 1.5x) — but `click_force` (actionability skipped, ~27.8ms/click) is the
  one that discriminates healthy builds.

**Gotchas:** `page.evaluate(<string>)` treats the string as an EXPRESSION, so a
bare arrow-function source returns `undefined` — invoke as `(${source})()`.
CommonJS on purpose: `playwright` is a global install and ESM ignores `NODE_PATH`
(pnpm's global layout also hides `playwright-core`, so resolve it via
`createRequire(require.resolve('playwright'))`). `libm_fmod` is split out
deliberately — see [[feedback_microbench_validate_in_situ]].

**Read the ratios, never the milliseconds**, and prefer layer bytes for size
questions ([[feedback_match_instrument_to_effect_size]]).

Related: [[project_alpine_browser_perf_vs_glibc]], [[project_chromium_dcheck_from_is_official_build]].
