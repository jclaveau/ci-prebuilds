---
name: project_wk_mimalloc_purge_delay_finding
description: WebKit's page-fault excess (×4.9-5.0 vs official) traces to mimalloc's purge policy on the webkit-side preload; MIMALLOC_PURGE_DELAY=-1 cuts faults 36% with no RSS cost but RESOLVED 2026-09-24 as a WASH — perf-probe.yml n=10 on 7763+9V74 read geomean 1.00 both CPUs, no row moved >2%; real mechanism, zero wall payoff, same shape as the ff PGO-corpus null result
metadata:
  type: project
---

2026-09-24, current lead for wk `input`/`click_force` after
[[project_wk_input_gap_not_node_allocator]]'s node-allocator AND
Mesa/llvmpipe theories both retracted same day.

Mined `browser-perf-record`'s `perf sched`/`perf stat` passes (not
previously read). **Total CPU is at parity**: 19382 vs 19613 ms (8370C),
20370 vs 19832 ms (9V74) — we do not burn more CPU overall, which is what
ruled llvmpipe back out.

What is up, both AMD draws, same sign:

| counter | 8370C ours/off | 9V74 ours/off |
|---|---|---|
| page-faults | ×4.9 | ×5.0 |
| madvise calls | ×2.7 | ×3.3 |
| cpu-migrations | ×1.60 | ×1.28 |
| context-switches | ×0.93 (fewer) | ×0.83 (fewer) |
| per-thread sched delay | 1.1x-2.3x, every thread | same pattern |

Cause: the webkit `pw_run.sh` wrapper preloads `libmimalloc-insecure.so.2`
into every webkit process; official preloads nothing. mimalloc's purge
policy generates the excess madvise/refault traffic.

**Confirmed locally via cgroup counters** (immune to the wall-clock drift
that killed the llvmpipe A/B), n=5 total per arm, non-overlapping runs:

| arm | cgroup pgfault | memory.peak |
|---|---|---|
| base | 240319/248300/234858/246157/244141 | 470.2/471.9 MB |
| `MIMALLOC_PURGE_DELAY=-1` | 157680/152647/156949/153262/157807 | **372.0/461.2 MB** |

Purge-off removes 36% of all page faults, deterministically, at equal or
LOWER peak memory — RSS was the one thing that could've made this
unshippable, and it's cleared.

**Not yet proven: that the faults cost wall time.** Kernel CPU share in the
click profile is LOWER on our arm — 19.36% of 62.46e9 = 12.09e9 cycles vs
official 22.65% of 60.97e9 = 13.81e9. The extra faults are cheap. What IS up
at flat total CPU is per-thread scheduler delay + migrations — cache/
placement, which the ×5 refault rate plausibly drives but doesn't yet prove.

**Incidental find, possibly bigger than the above:** both a secure and an
insecure mimalloc are loaded, split by process — the node driver's
MainThread runs `libmimalloc-secure` (2.01% CPU share), webkit's compositor
thread runs `libmimalloc-insecure` (0.13%, 15x less CPU).
[[project_wk_input_gap_not_node_allocator]]'s retracted secure-vs-insecure
A/B "came back flat" on an n=4 webkit-only test — that A/B may never have
varied the variable for the process that actually matters (the node
driver, not webkit). Re-read before building anything new on that
retraction.

**Next step, not yet dispatched:** `perf-probe.yml` already takes `image`/
`image_b` on the SAME runner plus `runs`/`replicates`/`want_cpus` — its own
`label` example text is literally `"wk mimalloc arm"`. No new workflow
needed. One branch adding `MIMALLOC_PURGE_DELAY=-1` to the webkit wrapper in
`playwright/Dockerfile.alpine:387` publishes a `sha-` image (consumer layer
only, no 4.5h webkit rebuild), then one dispatch prices the wall effect at
n=10 across 7763+9V74.

**RESOLVED 2026-09-24 — WASH.** Shipped the env change on `perf/wk-mimalloc-no-purge`
(PR #311, `a1ce63b`, `playwright/Dockerfile.alpine` +16) and priced it with the
exact instrument this memory named: `perf-probe.yml` dispatch 35987167093,
`image`=candidate sha vs `image_b`=shipped `latest`, same job/runner, webkit,
n=10, both 7763 and 9V74 drawn:

| row | 7763 cand/shipped | 9V74 cand/shipped |
|---|---:|---:|
| screenshot | 0.988 | 0.986 |
| click_force | 0.992 | 0.982 |
| eval_rtt | 0.992 | 1.010 |
| context_page | 1.006 | 0.986 |
| goto_cold | 1.009 | 1.000 |
| layout | 1.001 | 1.003 |
| launch | 0.996 | 1.003 |
| **geomean** | **1.00** | **1.00** |

No row moves beyond ±2%, no row moves the same direction on both CPUs. The
confirmed 36% fault cut and flat/lower RSS price at **zero wall time** — the
per-thread scheduler-delay/migration signal this memory flagged as
"plausibly driven by the refault rate but not yet proven" turned out not to
cost anything measurable either. PR #311 left unmerged, pending jean's call
(close vs keep) — see `open_user_rulings_carried_across_sessions`.

**How to apply:** wk `input`/`click_force` has now had three leads measured
and killed the same way — node allocator (flat, 3 CPUs), llvmpipe/Mesa
(total CPU at parity), mimalloc purge (geomean 1.00, n=10, 2 CPUs). Don't
re-propose any of the three. If the row resurfaces, it needs a fresh
mechanism, not a re-measurement of these.
