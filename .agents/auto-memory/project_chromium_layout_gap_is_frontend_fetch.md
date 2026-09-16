---
name: project_chromium_layout_gap_is_frontend_fetch
description: the chromium layout row (1.5x) is FRONTEND FETCH, not codegen — our hot code sits in TWO .text bands (CG-sorted +0-30 MiB and unsorted +120-131 MiB) vs official's one, link line identical to upstream; on the same 5 cpus our reflow kernel takes 2.3x the iTLB misses, 1.4x the icache misses and 2x the fetch-latency cycles per instruction, and our hot code spans 1.6x more 4K text pages (243 vs 154 for 90% of samples); the throughput kernel (boxonly, 1.1x) has flat caches and is plain +10% instructions; -M metrics need --for-each-cgroup and their % lines are junk under a cgroup
metadata:
  type: project
---

Dev box (i5-8350U, PMU works), `--cpuset-cpus=0-4`, shipped
`jclaveau/alpine-dood-playwright:latest` (chs-1234, clang23+PGO+ThinLTO+SSP cfg)
vs `mcr.microsoft.com/playwright:v1.62.1-noble`, 2026-09-15. Issue #249 item 1.

**`layout_reflow` (the campaign row's shape, 1.57x wall here):**

| per instruction | alpine | official | ratio |
|---|---|---|---|
| instr / iter | 1.39 G | 1.23 G | 1.13 |
| cycles / iter | 1.09 G | 0.81 G | 1.35 |
| IPC | 1.27 | 1.52 | 0.84 |
| L1i miss / kI | 76.4 | 54.8 | **1.39** |
| iTLB miss / MI | 141 | 60.5 | **2.34** |
| fetch-latency 0-uop cycles | 29.7 G | 15.0 G | **1.98** |
| branch miss % | 0.38 | 0.25 | 1.51 |
| L1d miss / kI, LLC miss / MI | | | 0.82, 1.04 |

Data side flat, instruction side doubled: the IPC loss is instruction FETCH.
The page census says why — `perf record` samples inside the main binary hit
859 distinct 4 KiB pages on ours against 734, and the pages holding 50% / 90%
of samples are **69 / 243 vs 42 / 154**: our hot code is 1.6x more spread
out. Both binaries are one 162 MB `.text` at 4 KiB LOAD alignment with no
`.text.hot`/`.unlikely` output sections, so this is function ORDER inside
`.text`, which PGO hotness + lld's section-prefix grouping decide. A profile
that mismatches many functions would produce exactly this — but #249 item 2
is DEAD (run 34811938326: ~7% mismatch on both sides, revision drift).

**Symtab (run 35026937666, `diag/chromium-symtab-dump`, r12 binary before
strip):** our hot reflow samples fall in TWO `.text` bands — `+0–30 MiB`
(lld's CG-profile-sorted cluster) and `+120–131 MiB` (hot Blink functions
left in input order, e.g. PhysicalBoxFragment / LayoutBlockFlow) — where
official's fall in ONE. The link line is upstream Linux verbatim (CG sort on,
no orderfile, no `-z keep-text-section-prefix`, no machine-function
splitting), so the second band is functions the PGO call-graph profile has no
edges for. Candidate: link-only `--symbol-ordering-file` from our own perf
profile (6206 symbols, top 1000 = 87% of samples, 10.4 MiB) re-linked in the
r12 image with `ninja -t commands` line — `probes/chs.orderfile` +
`build-flags-probe.sh` on that branch, run 35028710882.

Also: wall 1.57x but cycles 1.35x — ~15% of the reflow gap is NOT CPU work
(we burn fewer total cycles in the window). Threads waiting; unattributed.

**`layout_boxonly` (throughput, 1.12x wall):** icache 1.06, iTLB 1.08,
fetch-latency 0.98, data misses 0.85 — flat. +10% instructions, IPC 0.88.
Plain codegen, no stall signature. Small.

**Instrument traps.** `perf stat -M TopdownL1 -a -G /` dies "must define
events before cgroups"; `-M TopdownL1 -a --for-each-cgroup /` runs. But the
tma_* percentages it prints are junk under a cgroup (108% frontend, -61%
backend: `THREAD_ANY` counts both hyperthreads) — read the RAW event counts
normalised by `INST_RETIRED.ANY`, and prefer the short explicit `-e` lists
(60-75% coverage) over the L2 group (25-40%, inconsistent across blocks).
Scripts: `probes/perf-topdown.sh`, `probes/perf-pages.sh`.
[[project_chromium_layout_is_diffuse_no_hotspot]] [[project_chromium_residual_gap_candidates]]
