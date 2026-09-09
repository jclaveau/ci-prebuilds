---
name: chromium_build_time_is_cold_vs_warm_not_pgo
description: PGO+ThinLTO cost ~10% of the chromium chain, not the bulk — the 4h and 7.7h runs people remember are cache hits, and they happen on both sides of the knobs
metadata:
  type: project
---

Chain hours summed over the `from-source` round jobs (serial, so ~= wall clock),
every full chain since July. PGO+ThinLTO became default in `0384a77` (#103) on
2026-08-24:

    2026-07-13  29228599510   3.9h   feat/webkit-alpine-branch-c   (WARM)
    2026-07-29  30449808620  39.2h   main
    2026-08-06  31100055793  41.6h   fix/finalize-overlay-stage-cache
    2026-08-12  31596578641  39.1h   main
    2026-08-14  31799231829  44.5h   perf/chromium-pgo
    2026-08-19  32228875384   3.0h   feat/pw-1.62.1-sweep          (WARM)
    2026-08-19  32262979614  36.1h   feat/pw-1.62.1-sweep   <- baseline, NEITHER knob
    2026-08-21  32530923539  40.7h   perf/chromium-pgo-thinlto-1.62
    2026-08-24  32745725864  40.3h   main                          PGO+LTO
    2026-08-27  33084475914   7.7h   main                          PGO+LTO (WARM)
    2026-09-06  34049211352  36.5h   main                          PGO+LTO

Before the knobs 36.1-44.5h, after 36.5-40.3h. The single-variable same-week
pair is baseline **36.1h** against both-knobs **40.7h** — the +10% the A/B
already reported, and **nothing in the history is faster than the knobs-on
runs**.

**Cold vs warm is the 5x variable; PGO/LTO is the 1.1x one.** The 3.0/3.9/7.7h
rows are chains that reused existing round images (`reuse-if-exists` on
rev+recipehash), and they occur on BOTH sides of 2026-08-24 — 7.7h is a
post-PGO run. That is what "the build was much faster before" is remembering.

The warm path is structurally unavailable to an experiment: any candidate worth
measuring changes the build, which changes the recipe hash, which forces a cold
r1..rN ([[project_chromium_round_images_sha_keyed]]).

**Why:** "turn PGO/LTO off while iterating" keeps coming up as the way to stop
waiting 38h. It buys ~4h of ~38 and costs the transferability of the result —
the two knobs were super-additive with EACH OTHER (1.28 / 1.31 alone, 1.12
together), so effects on this binary demonstrably do not compose independently,
and a candidate screened at baseline may not survive the shipped config.

**How to apply:** the free lever is throughput, not latency — the concurrency
group is per-ref, each chain holds one job at a time, and runner-minutes are
unbilled on a public repo, so 4-6 candidate branches can run at once. Pair each
arm to the official control leg in its OWN run
([[project_perf_probe_ratio_is_cpu_dependent]]). Larger runners are out of scope
— jean will not spend money on this repo.
