---
name: project_wk_input_gap_not_node_allocator
description: RETRACTED TWICE 2026-09-24 — node-allocator theory dead, THEN the llvmpipe/Mesa theory that replaced it also dead (total CPU at parity, llvmpipe itself below parity on one CPU); current lead is mimalloc purge/page-faults, see [[project_wk_mimalloc_purge_delay_finding]]
metadata:
  type: project
---

wk/ff both meet parity except webkit **input 1.04** (n=5-6, 2-3 CPUs,
consistent, 5/6 draws >1.00).

**Node-allocator theory (tested and dead, first pass):** perf-record on one
host pointed at node MainThread +8.5%, suspecting the consumer image's
container-wide `LD_PRELOAD=libmimalloc.so.2` → mimalloc-**secure**, vs every
browser's own shim preloading mimalloc-**insecure** for itself. Local A/B
(webkit, n=4/arm, secure vs insecure vs none) came back flat — eval_rtt
445.7/466.2/492.2, click_force 933.0/967.9/1079.5, locator_click
3304/3332/3358, all within ~±15% noise. No Dockerfile change shipped.

**Root cause found (three-CPU probe, 2026-09-24):** three existing
`browser-perf-record` webkit runs (2026-09-21) already had both arms in one
job per CPU model — nobody had summed per-thread CPU before. Per-thread
cpu-clock count, ours/official:

| thread | 7763 | 9V74 | 8370C |
|---|---|---|---|
| **llvmpipe-0..3** | **1.252** | **1.162** | 0.896 |
| WPEWebProcess | 0.993 | 0.987 | 0.993 |
| node MainThread | 0.982 | 1.026 | 1.108 |
| MiniBrowser | 0.847 | 0.926 | 1.048 |
| ReceiveQueue | 0.706 | 0.935 | 0.982 |
| **total CPU** | 1.034 | 1.024 | 0.995 |

`llvmpipe` is 30% of all CPU in a click loop and the only thread off parity;
node MainThread is 0.98/1.03/1.11 — flat, not "+8.5%, the whole gap" as the
first pass claimed (that reading does not replicate here). DSO level, same
run: ours `[JIT] tid` 26.93% + `libgallium-26.1.6.so` 3.99%; official `[JIT]`
20.81% + `libgallium-25.2.8-0ubuntu0.24.04.2.so` 4.23% — the `[JIT]` frames
are llvmpipe's LLVM-generated shaders, single hottest address 11.86% ours vs
7.18% theirs. **Mesa 26.1.6 (ours) vs 25.2.8 (official)** is the delta.
llvmpipe loses on 7763+9V74 = 77% of draws, wins on Ice Lake (8370C) —
exactly the row's "1.04, 5/6 draws >1.00" shape.

**Mesa/llvmpipe theory also retracted (2026-09-24, same day):** the local A/B
(base / `WEBKIT_DISABLE_COMPOSITING_MODE=1` / `LP_NATIVE_VECTOR_WIDTH=256`)
meant to price the llvmpipe share went dead — throughput climbed
monotonically with run order regardless of arm (laptop drift swamped the
effect), discarded unread. Went back to the same CI artifacts' unmined
`perf sched`/`perf stat` passes instead: **total CPU is at parity**
(19382 vs 19613 ms on 8370C, 20370 vs 19832 on 9V74) and llvmpipe's own
runtime reads *below* official (0.896) on the run where every thread's
sched delay is still up — it cannot be the driver of a gap it doesn't
itself show. The Mesa-pin plan is dropped with it (mesa 25.1.9 exists in
alpine v3.22 but would drag llvm20-libs onto an edge base for a lever the
counters no longer point at).

The real signal — page-faults ×4.9-5.0, madvise ×2.7-3.3, sched-delay
1.1-2.3x on every thread at flat total CPU, traced to mimalloc's purge
policy on the webkit-side preload — is written up in
[[project_wk_mimalloc_purge_delay_finding]]; that is the current lead, not
this file's Mesa/llvmpipe conclusion.

**How to apply:** if wk input/click_force resurfaces, start from
[[project_wk_mimalloc_purge_delay_finding]] (mimalloc purge / page-fault
rate). Do NOT re-open the node-allocator theory (dead, flat on 3 CPUs) or
the Mesa/llvmpipe theory (dead, total CPU at parity) without genuinely new
evidence — both were each independently proposed and killed the same day.
