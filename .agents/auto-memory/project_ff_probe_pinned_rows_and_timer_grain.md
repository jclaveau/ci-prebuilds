---
name: project_ff_probe_pinned_rows_and_timer_grain
description: firefox pins THREE runtime-probe rows by physics, not by build quality — locator_click and click_force at whole 60Hz frames and int_math on imul latency — and every firefox in-page kernel is measured at 1 ms grain because performance.now() is clamped on both sides
metadata:
  type: project
---

Chasing "every metric strictly < 1.00 vs official" needs the rows that CANNOT
move separated first, or a build arm gets credited or blamed for a constant.

**Three rows are pinned for firefox, not one.** From run 33056825499 (three
arms, one runner) plus the n=5 baseline 33063971129:

| row | firefox | why |
|---|---|---|
| `locator_click` | 5000.x ms = 100 x 50.0 ms | frame cadence, already documented |
| `click_force` | **1666.7 ms = 100 x 16.667 ms** | **exactly one 60Hz frame** |
| `int_math` | **37-39 ms on all nine arms** | CPU latency chain |

`click_force` is NOT the unquantized twin here. It is unquantized for the other
two engines — chromium 4.55-5.56 ms/click, webkit 4.90-6.58, both varying
freely — but every firefox arm lands on 16.666-16.684 ms/click: alpine
1667.0/1682.3/1666.7/1666.9/1666.6 against official
1666.3/1667.6/1666.5/1667.5/1668.0. We are already ON the frame boundary and
official sometimes spills just past it, which is the whole of our 0.99-1.00.
Nothing below ~0.99 is reachable without dropping frames.

`int_math` is 30M iterations of `x = (Math.imul(x, k) + c) | 0` — a serial
dependency chain, ~3.5 cycles/iter, i.e. imul latency + add. It reads 37.0-39.0
ms across **three JS engines** (V8 37.4, SpiderMonkey 37.0, JSC 38.0-39.0), two
libcs and both images. No build flag can move a hardware latency.

**Every firefox in-page kernel is measured at 1 ms grain.** Measured directly
(smallest non-zero `performance.now()` delta over 400k reads): **1 ms on ours
AND 1 ms on official** — symmetric, so unbiased, but it caps resolution:

| kernel | firefox median | resolution at 1 ms |
|---|---|---|
| `js_alloc` | ~19-21 ms | **±5%** |
| `dom_churn` | ~32-34 ms | ±3% |
| `int_math` | ~37 ms | ±2.7% |
| `libm_fmod` | ~70 ms | ±1.4% |
| `layout` | ~100 ms | ±1% |

So `js_alloc` cannot support a sub-5% claim in either direction, and it is the
row that reads 1.00 / 0.905 depending on how the runs are pooled. WebKit reports
integer ms too; only chromium gives sub-ms (37.4, 55.3, 6.5, 28.7).

**The fix is one launch pref and it is verified**: `privacy.reduceTimerPrecision:
false` (+ `privacy.resistFingerprinting: false`) takes the grain from 1 ms to
**0.02 ms**, 50x finer, and js_alloc then reports 49.280 where it reported
49/52/66. It belongs in `playwright/bench/runtime-probe.cjs`'s launch, applied
to BOTH arms so it stays a fair control.

**How to apply:** before crediting any arm on `js_alloc` or `dom_churn`, check
the delta exceeds the grain; and never open a work item on `click_force`,
`locator_click` or `int_math` for firefox.
[[project_runtime_perf_probe]], [[feedback_match_instrument_to_effect_size]]

**2026-08-27 — at n=10, TEN of the thirteen firefox rows are statistically
TIED, and n=5 manufactures false verdicts.** Run 33066912135 (`runs=10`,
EPYC 7763, both arms in one job), scored by what fraction of the 100 cross-run
pairs has alpine faster — a median on one side is not separation:

| verdict | rows |
|---|---|
| CLEAN faster (100/100) | `dom_churn` 0.780, `libm_fmod` 0.665 |
| CLEAN slower (0/100) | **`layout` 1.065** |
| tied (everything else) | `context_page` 69/100, `goto_cold` 61, `js_alloc` 57, `launch` 57, `click_force` 57, `locator_click` 52, `goto_warm` 39, `screenshot` 36, `eval_rtt` 23, `int_math` 16+68 tied |

**`context_page` was 25/25 "CLEAN faster" at n=5 and is only 69/100 at n=10.**
That is the n=5 trap in one row: five draws produced a confident verdict that ten
draws withdrew. Do not promote a row to "won" off n=5.

**So a "ratio < 1.00 on every metric" goal is not decidable on most of these
rows with this instrument**, and not because we are slower — because the per-row
spread dwarfs the difference. `goto_warm` is 26-37 ms against 26-36 ms: a ~2%
effect inside a ~40% spread will not separate at any n we would pay for. Needed
n scales as (spread/effect)^2, so:

- resolvable today: `layout` (5% spread vs 6.5% effect), `dom_churn`,
  `libm_fmod`, and marginally `eval_rtt` / `js_alloc`;
- structurally unresolvable: `goto_warm`, `goto_cold`, `context_page`,
  `launch`, `screenshot` — these need *quieter kernels* (longer, more
  deterministic, more repetitions inside the page), not more container restarts,
  and that is a `playwright/bench/` change.

**How to apply:** report these rows as "at parity, indistinguishable" rather than
as wins or as work items, and spend build budget only on rows the probe can
actually resolve. [[feedback_match_instrument_to_effect_size]],
[[feedback_size_verification_to_failure_rate]]

**A row whose NULL arm is off 1.00 cannot resolve its own effect size.** The
three-arm probe's `ubuntu` arm is the instrument's null — same browser binary,
so any deviation from 1.00 there is the harness, not the build. When that null
sits at 1.11-1.12 on a row (`goto_warm` did, and the webkit arm hit the same
thing), the row's own noise floor is >10%, and an arm landing anywhere inside
that band is reporting the SIGN of a coin flip.

So for those rows: report "inside the null arm's band, not resolvable" rather
than the direction. This is the same rule as the n=10 tie list above, stated
against a per-row reference instead of a cross-pair count — and it is cheaper
to apply, because the null arm is already in every three-arm run.
