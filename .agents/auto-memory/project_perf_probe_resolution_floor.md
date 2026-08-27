---
name: project_perf_probe_resolution_floor
description: A null pair (same image, same CPU model, two runs=5 probes) gives each metric's noise floor — goto_cold cannot resolve better than 0.12 and click_force 0.07, while goto_warm/layout/eval_rtt resolve to 0.01 or better
metadata:
  type: project
---

Pairing by CPU model is necessary but NOT sufficient
([[project_perf_probe_ratio_is_cpu_dependent]]). Two `runs=5` probes of the
SAME image on the SAME CPU model still disagree, and by wildly different
amounts per metric. Measured directly (runs 33086652861 and 33086685768, both
`edge`, both AMD EPYC 9V74, `libm_fmod` fingerprint 3.07 / 3.12):

```
metric          |delta|      metric           |delta|
goto_cold         0.12       context_page       0.02
click_force       0.07       goto_warm          0.01
libm_fmod         0.05       screenshot         0.01
js_alloc          0.03       layout             0.00
launch            0.02       dom_churn          0.00
                             eval_rtt           0.00
                             int_math           0.00
                             locator_click      0.00
```

**How to use it.** Before quoting a delta, check it against its row's floor. A
single-pairing move of 0.05 on `goto_cold` is unreadable; the same move on
`layout` is real. Repeat the pairing when a delta is within ~2x its floor.

Two corrections this forced on my own earlier claims:

- the mimalloc `goto_cold` result (1.48 -> 1.09-1.15, a 0.33-0.43 move across
  three pairings) clears the 0.12 floor comfortably — it stands.
- `goto_warm` is one of the SHARPEST rows (0.01), not one of the blurriest.
  Its bad reputation came from the pre-#129 fixture where it was ~24 ms
  absolute; #129 rescaled it to ~268 ms. The +0.03/+0.06/+0.20 spread I once
  reported as a regression was the instrument at 24 ms, and I twice reasoned
  about it as though it were the allocator.

**Getting a null pair is nearly free** — dispatch any image twice and difference
it against itself. Do it once per campaign rather than inferring floors from
the spread of arms that also differ in content. Note perf-probe's concurrency
group is keyed on `inputs.image` and keeps only ONE pending run per group, so
two identical dispatches evict each other: vary the ref spelling (tag vs
`@sha256:` digest) to get concurrent draws of the same image.
