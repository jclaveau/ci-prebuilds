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
