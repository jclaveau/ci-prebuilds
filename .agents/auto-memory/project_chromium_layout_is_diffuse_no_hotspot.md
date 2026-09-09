---
name: project_chromium_layout_is_diffuse_no_hotspot
description: chromium's worst row (runtime-probe `layout`, 1.47-1.52x) has NO hot function — the hottest address in the whole profile is 0.38% of the main binary — so profiling harder cannot find it and the only lever is build configuration; also the two layout kernels are confirmed two different costs on one runner
metadata:
  type: project
---

Run 34361054761, EPYC 7763, `layout_reflow` and `layout_boxonly` profiled back
to back on one machine against the same official arm.

**The two layout kernels are two different costs — settled.** They read
**1.47x** and **1.31x** in the same run on the same machine, which no earlier
run could show because `perf-kernel.cjs` had no kernel matching the campaign
row. The difference is shape: `layout_boxonly` does 300 reflows that each
re-lay-out 800 children, so it is bound by layout THROUGHPUT, while the
campaign row does 16,000 reflows of a single bare div, so it is bound by the
FIXED cost of entering a forced synchronous reflow. `layout_reflow` (added the
same day) mirrors the campaign kernel down to the 800 pad rows around it.

**There is no hot function, and this is what kills "profile harder".** 94.9% of
alpine's time is inside `chrome-headless-shell` itself (official 94.1%), so the
gap is chromium's own code and not libc or the loader — but the hottest single
address in the entire profile is `[vdso]` at **1.24%**, and chromium's own
hottest is **0.38%**. A 68 ms delta with no peak above 0.4% is diffuse by
construction. Same shape the earlier read found for `layout`
(+16% instructions at -13% IPC). The lever is build configuration — SSP
parity, PGO, ThinLTO — not a fixable function.
[[project_chromium_perf_record_first_read]] [[project_chromium_perf_arms_1_62]]

**Two traps in reading this profile.**

Both artifacts ship STRIPPED (the perf Dockerfile's own comment says so), so
only `.dynsym` resolves: `_start`, `avx2_set`, a `rust_png$cxxbridge` export,
and otherwise raw addresses. Naming a hot address means disassembling it in
place, and that is only worth doing if a peak exists — here none does.

And `*-sym.txt` is TRUNCATED (~72 lines). Summing it and dividing gives a
"top 200 is only 11.7% of time" figure that is an artifact of the head, not a
measurement. The report is sorted descending, so the file supports "nothing
below line 72 exceeds 0.16%" and nothing about totals.

**No hardware PMU, twice.** Runs 34342006293 and 34361054761 both returned
`<not supported>` for cycles/instructions/branches/cache on BOTH arms, so IPC
and stall counters were unavailable. An earlier run did have them
(+16% instructions at -13% IPC is on record), so PMU exposure is per-runner
like the CPU model — an empty stat block means draw again, not "the counters
say nothing". [[project_perf_probe_ratio_is_cpu_dependent]]
