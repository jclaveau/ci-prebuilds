---
name: project_alpine_browser_perf_vs_glibc
description: musl is NOT the reason alpine browsers are slower — Firefox and WebKit are at parity or faster than the official glibc builds; only chromium is slow, and that is a build-config bug not a libc one
metadata:
  type: project
---

Measured 2026-08-12, our alpine images vs PW's official glibc images, same probe
in both (local docker, alpine even given `seccomp=unconfined`, i.e. an advantage):

| | alpine | official | verdict |
|---|---|---|---|
| firefox math / jsAlloc / dom / layout | 1026 / 560 / 96 / 887 ms | 1662 / 559 / 116 / 869 | **parity or faster** |
| webkit intMath / sqrt+log | 38 / 66 ms | 44 / 142 | **faster** |
| chromium layout / dom / jsAlloc / intMath | 6279 / 416 / 964 / 94 ms | 677 / 58 / 337 / 50 | **9.3× / 7.2× / 2.9× / 1.9×** |

Also at parity: DNS (`getaddrinfo` 34 vs 31 ms — musl's resolver is not a
factor), node boot (0.18 vs 0.20 s), browser launch (chromium 548 vs 540 ms),
fontconfig. The strip/dedup work has no perf cost.

**So: don't reach for "musl is slow" / "no PGO on musl" / "fontconfig cold" when
an alpine number looks bad.** The single real regression was chromium's
[[project_chromium_dcheck_from_is_official_build]].

**Two narrow, genuine musl gaps** (both harmless in practice):
- `fmod()` is a portable C implementation, ~2.1× glibc. Reaches JS only through
  `%` on non-int32 doubles. It is NOT a JIT problem — WebKit ships all tiers
  (`strings` on libWPEWebKit: DFG 1062 / FTL 223 / B3 674 / Air 191, `CLoop` 0).
- Nothing else surfaced across four workload classes.

**How to apply:** benchmark "time to tests" gaps are launch+execute combined —
split them (launch, newPage, about:blank, cold goto, warm goto) before theorising,
and use a libc-free CPU kernel ([[feedback_microbench_validate_in_situ]]). A gap
that lands only on the C++ heap/layout paths while JIT-generated code is at parity
points at the BUILD CONFIG, not the libc.

**2026-08-13 — same-runner probe, attributing the bench's `test` column.** Alpine
is 1.92x official in chromium-only mode and 1.59x for all three. Per browser
(alpine ÷ official, same runner):

```
             launch  context_page  goto_cold  goto_warm  dom_churn  layout
chromium      1.94x     2.29x        3.58x      6.78x      5.30x    104x   ← DCHECK
firefox       1.45x     1.24x        1.55x      1.30x      1.11x    1.21x
webkit        1.15x     1.27x        1.14x      1.41x      0.97x    1.00x
```

Chromium (still the DCHECK build) explains the chromium-mode gap exactly: the
fixture is launch + newContext + newPage + goto, i.e. the 1.94/2.29/3.58 metrics.
WebKit contributes ~nothing. Firefox's residual is startup-only — `launch` 1.45x,
`goto_cold` 1.55x — genuine musl process-startup/dynamic-linking cost that the
chromium fix will NOT remove. **The bench understates the DCHECK penalty**: its
trivial spec barely touches layout, so it shows ~1.9x while layout alone is 104x;
real suites re-pay layout on every actionability poll, which is where "50% slower"
came from.

**1.62.1 re-measure (2026-08-21), one job per A/B so the CPU is held constant.**

chromium from-source vs `Google Chrome for Testing` (run 32458305232), ratio =
official/alpine, lower = alpine slower: layout **0.44x**, dom_churn **0.60x**,
goto_warm 0.64x, click_force 0.74x, launch 0.84x — but int_math 1.00x, js_alloc
0.86x, **libm_fmod 1.00x**. Compute at parity, rendering 2.3x off ⇒ build
config, not musl. Conformance suite-time in the same run: +15.5% library,
+13.6% page, +25.2% stress (DCHECK era was +27%).

firefox 153.0 vs official 153.0 (run 32460180480): essentially parity —
layout 0.86x, launch 0.91x, most metrics inside their own spread. **libm_fmod
1.43x, i.e. our musl build is FASTER**, which contradicts the "musl fmod ~2.1x
slower" claim in `runtime-probe.cjs`'s header comment — re-verify before quoting
it. Sole real FF regression is screenshot 0.68x, see
[[project_ff_png_encoder_gap]].

**2026-08-25 — the three-arm `perf-firefox` job separates ENVIRONMENT from
BUILD; read it that way or you misattribute.** Run 32782133911, all arms on one
runner (EPYC 9V74), FF 153.0, PW 1.62.1.

The `ubuntu` arm is NOT our Firefox on glibc. `playwright/Dockerfile` runs
`playwright install`, so it carries **PW's own binary** — the same build the
official image ships. So:

- `ubuntu/official` = our IMAGE vs PW's image, browser held constant → ENV.
- `alpine/ubuntu`   = our musl BUILD vs PW's binary, image roughly constant.

| metric | ENV (ubu/off) | OUR BUILD (alp/ubu) |
|---|---|---|
| screenshot | 1.08 n.s. | **1.20** |
| launch | 1.00 n.s. | **1.16** |
| layout | 1.00 n.s. | **1.09** |
| eval_rtt | **1.14** | 1.00 n.s. |
| libm_fmod | 1.00 n.s. | **0.59** (musl faster) |

`>1.00 = slower` — the INVERSE of chs-perf-ab/ff-perf-ab, which print
official/ours. n.s. = delta inside summed half-IQRs (IQR, not range: alpine's
`context_page` carries a 1158 ms outlier among ~250 ms samples).

**So our build's real deltas are exactly three** — screenshot, launch, layout —
and `eval_rtt`'s 14% belongs to our ubuntu image's runtime, not to Firefox. A
two-arm ours-vs-official comparison cannot see that difference and charges it
to the browser. `libm_fmod`'s 1.00 on the ENV column is the harness's own
control: identical binary, identical number.

**How to apply:** for any "is this our build or our packaging?" question, use
this job's three arms, not `ff-perf-ab`'s two. [[project_ff_png_encoder_gap]]
(screenshot is capture/readback, not encode),
[[feedback_check_reference_stability_across_runs]]
