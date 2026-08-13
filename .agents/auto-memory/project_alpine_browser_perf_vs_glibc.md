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
