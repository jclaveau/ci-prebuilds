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
