---
name: parked_chromium_residual_tracks_2026_10_08
description: Chromium perf tracks jean parked 2026-10-08 (A2-A9, B3-B5, C2-C7) while A1/B1/B2/C1 ran; evidence per track, resume on ask
metadata:
  type: project
---

jean 2026-10-08: "go A1, B1, B2 on famille and C1. park the others for later".
Parked, not dead. Resume only on ask.

A — half-done / forgotten
- A2 fontconfig still system: fc-match 5.8 vs 4.9 ms (ours vs official) per cold text init.
- A3 goto_cold page_new +0.7-1.1 ms never decomposed; T8 never run.
- A4 9V74 scaling: residual larger on EPYC 9V74 than 8573C, never explained.
- A5 dom_churn iTLB 1.33x: code placement (see [[project_chromium_layout_gap_is_frontend_fetch]]).
  2026-10-08 famille counted: wall 350.7 vs 340.1 ms (1.03x), cycles/iter 714 vs 697 M (1.02x), insn/iter 1310 vs 1500 M (0.87x) — fewer insn, lower IPC: L1i miss/kI 1.15 vs 0.39 (2.9x), iTLB miss/MI 27.2 vs 15.4 (1.77x). Frontend shape persists for dom_churn (T4 checked only reflow). Ceiling ~2-3% wall; lever = orderfile relink (B4), CI ~3 h, not dispatched.
- A6 screenshot XR surface format: readback/convert path vs official unchecked.
  2026-10-08 famille counted screenshot_png: NO local gap — ours 54.69 vs official 56.08 ms median (0.98x), CPU 67.6 vs 68.5 ms/iter, insn 164 vs 154 M/iter (1.06x), cycles 87.5 vs 84 M (1.04x), same PNG bytes (5049B 3fcc38dbe229). chrome .real 35.1 vs 35.3 ms; libfaststring 9.9 vs glibc libc 12.2 ms. CI 1.24-1.50x (Intel) is runner-specific, like A3 → folds into A4/C4 (needs CI, ask).
- A7 rep movsb memcpy 2 KB-1 MB: musl memcpy vs glibc ERMS path in that band. CLOSED 2026-10-08 unrun: all memcpy+memset = 1-2% CPU (09-28 count), faststring tries sat in a 3-7% null spread; ceiling below the noise floor.
- A8 sh wrapper +4-5 ms per launch. DONE 636a781 (${0%/*}); also lavapipe aa781a1 + GStreamer registry ac64224, see [[project_launch_cold_costs_2026_10_08]].
- A9 node driver JIT: 1.9-2.6x instructions vs official node. CLOSED 2026-10-08: dom_churn counted `node` DSO 2.10 vs 2.16 ms/iter, same V8 config (snapshot, code cache, no ptr compression, maglev); old ratio predates mimalloc-insecure preload, T7 node 146 vs 226 ms/iter.

B — never explored
- B3 huge pages for .text (THP / hugetlb remap of chrome .text).
- B4 relink ordering (symbol order file) for dom_churn/goto.
- B5 is_cfi vcall-only (drop icall, keep vcall) — distinct from dead cfi-icall-off candidate? check before resuming.

C — missing measurements
- C2 screenshot row frame-quantized / blind.
- C3 no fresh-context goto_cold counted kernel. STALE: kernel exists since ee8a0e5 (09-20). 2026-10-09 famille counted, NO local gap: goto_cold 126.25 vs 130.61 ms median (ours vs official, 0.97x), insn 341 vs 360 M/iter (0.95x), cycles 420 vs 423 M (0.99x); context_page 59.82 vs 62.39 ms (0.96x), insn 147 vs 153 M (0.96x). CI 9V* 1.09-1.12 → runner-specific, folds into A4.
- C4 few Intel draws.
- C5 official unsymbolized (perf report on official is addresses only).
- C6 CI runners have no PMU.
- C7 famille ±5% swing under load untested. DONE 2026-10-09 A/A (same perf-alpine:counted image as 2 candidates, sequential, load 1.2-1.4): dom_churn wall 344.3 vs 350.4 ms (0.98x), CPU 0.99x, BUT insn/iter 0.92x and cycles/iter 1.07x; screenshot_png wall 1.01x, insn 1.00x, cycles 1.03x. So famille null spread = ~2% wall/CPU, ~3% cycles on short kernels, up to 7-8% insn/cycles per iter on dom_churn (20 s time-window stat, multiplexed 67-88%, GC/JIT timing). A5's insn 0.87x / cycles 1.02x sit at the edge of that; only its L1i 2.9x / iTLB 1.77x ratios clear it.

Also parked under the for-testing family ([[parked_for_testing_image_family]]):
BRP off, SSP off, fortify off, libc++ hardening NONE, Thorium flags, march v3/v4.
Dead (do not resume): self-PGO, libc ladder, static node, faststring, march-v3,
libcxx-fast, cfi-icall-off.
