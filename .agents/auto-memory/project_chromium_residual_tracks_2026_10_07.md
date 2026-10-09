---
name: project_chromium_residual_tracks_2026_10_07
description: every strategy left for chromium's remaining rows above official after faststring shipped (d577feb) — goto_cold/context_page (waiting, not work, worst on Zen4 9V*), layout 1.011 (per-cycle, hot-code spread), click_force ~1.01 (node driver) — with status per track; jean 2026-10-07 ~00:30 Paris: start all in parallel, loop until each is validated or dead, ask before using jean's PC or famille-laptop
metadata:
  type: project
---

Baseline: 7 perf-gate draws of chs-latest+faststring vs official 1.62.1
(37524874478, 37527624043..37527644796; 3x 7763, 1x 9V45, 3x 9V74, no
Intel). Geomean 0.986-1.011. Table rebuilt by `tmp/fs-vs-official.py
tmp/fsgate-*.log`.

| row | ours vs official | real? |
|---|---|---|
| goto_cold | 50.5 vs 48.8 ms (1.03) 7763 .. 47.5 vs 42.4 ms (1.12) 9V74 | yes, 7/7, shots separate |
| context_page | 0.96-0.99 on 7763, 1.03-1.11 on 9V* | yes on 9V* |
| layout | 1.011 geo, 6/7 >1 (147 vs 144 ms 7763) | yes, floor ≤0.01 |
| click_force | 1.0097 pooled, CI 0.998-1.021 | marginal, floor 0.07 |
| dom_churn / eval_rtt | 0.983 / 0.995 | no |
| screenshot | 1.000 | row is blind (frame-quantized 16.7 ms/shot) |

Known facts (do not re-derive):
- goto_cold is WAITING not work: laptop insn 0.98x, cycles 1.01x; CI 8573C
  35590487107 wall 1.11x vs CPU 1.04x, ctx-switches +28% renderer
  main/ChildIO/IO. Ours scales worse with faster cores (7763→9V74 official
  ×0.86, ours ×0.89). goto_warm at parity → cost is per fresh context/renderer.
- Faststring does not touch goto_cold on 9V*; layout gap 1.027→1.011 with it.
- layout: chrome runs 1154 vs 1192 M insn/iter (0.97x official), musl left
  ~0.2%, hardening traps 0.77-0.94x → leftover is per-cycle.
- click_force: chrome CPU 973 vs 973 ms (locator_click, laptop); node driver
  373 vs 358 ms (+4%), node is 21-29% of the row.

Dead (do not re-propose): tz/ICU walk, DSO closure/musl loader, libc string
routines on nav, .ttf font swap, mremap/fcntl, static node swap, mimalloc
driver preload, fortify (subsumed), march-v3, libcxx-fast, cfi-icall-off,
self-PGO, stack-clash, libc ladder (parked). Below-official-hardening levers
(BRP off, SSP off, libc++ NONE, Thorium flags) parked → [[parked_for_testing_image_family]].

Tracks (status updated as they land):

| # | track | answers | where | status |
|---|---|---|---|---|
| T1 | probe split of goto_cold/context_page into ctx_new / page_new / first goto / close + renderer-process count after newPage + fc-match timing, diag branch, perf-gate x3 | which phase holds the 3-5 ms; spare renderer?; slow fontconfig? | CI | round 1 (37534427145/430493/434399, all 7763): gap = page_new +0.7-1.1 ms + first_goto +0.6-0.7 ms; renderer count identical every arm (spare-renderer DEAD); fc-match warm 9.2 vs 8.3 ms. Round 2 (6973P-C/7763/9V74): goto_cold 1.09-1.12; first_goto 12.3 vs 11.0 / 16.8 vs 15.3 / 15.8 vs 14.5 ms (1.09-1.12) on all 3, page_new 1.00-1.08, second goto parity → gap = FIRST goto of a fresh page. Round 3 bef12af (37542435911/439298/442907, candidate textstack, promoted chs-latest): RESULT (6973P-C/9V74/7763): chs-latest vs official — first goto no-text 1.09/1.07/1.02, then FIRST TEXT in the same renderer (one word) 5.9 vs 5.0 / 6.4 vs 5.4 / 8.0 vs 6.8 ms (1.18/1.19/1.18). Textstack vs official: first text 1.06/1.04/1.04, first goto 1.02/1.01/1.03, goto_cold 0.98/0.97/1.03, context_page 0.98/0.91/0.89. → the cold-nav gap IS first-text init per renderer (system freetype/harfbuzz); textstack closes most of it. Left: page_new 1.02-1.09, first text +0.2-0.3 ms (fontconfig? fc-match 5.8 vs 4.9 ms). VALIDATED |
| T2 | perf-gate candidate=textstack `chs-fs-sha-6e56156c78ac20a9d449e07ccc8917413f46e454` vs promoted chs-latest x3 | is textstack's old goto_cold ratchet 0.93-0.98 real on wall (only lever ever to move the row) | CI | round 1 (37534295003/298070 7763, 301706 Intel): goto_cold ratchet 0.95/1.00/0.97 (7/7 ≤1.00 with old draws), geo ratchet 0.992-0.997, vs official goto_cold 0.99-1.05, context_page 0.96. No 9V draw yet; round 2 (7763/9V45/9V74): ratchet goto_cold 1.00/0.96/0.95, launch 0.99/0.96/0.89, geo no row >1.03; vs official goto_cold still 1.05/1.04/1.03 → textstack trims ~half the 9V gap, does not close it. Ship = jean's ruling |
| T3 | chromium-gap-probes perf-record on goto_cold,goto_warm (perf sched wakeup latency, cpu-clock, strace, trace) | where wall-over-CPU waits (futex/condvar, thread create/munmap IPIs, fontconfig) | CI | 37534305636 (7763): goto_cold wall 1.01x, CPU 0.98x, ctx-switches 1.05x (ChildIOT/IOThread/main +20-27%), wakeup delay LOWER on ours; libharfbuzz 2.08 ms/iter (system, textstack bundles it). 7763 near parity → 9V gap uncaptured; rerun 37540507956 on 9V74: goto_cold 70.5 vs 69.0 ms (1.02x), CPU 0.99x — the perf-record kernel (rows=800, steady loop) does not reproduce the gate's first-goto gap; T3/T8 can't see it |
| T4 | hot-code spread of today's chs-latest vs official from saved data (two hot regions?) | does a relink ordering file still have something to fix | local light python | DONE: pages for p50/p90/p99 of samples equal (layout_reflow 34/132/242 vs 32/131/245); 2nd band 1.0-2.2% vs 0.9-1.3% → no spread to fix |
| T5 | ordering-file relink of current image, then gate x3 | layout 1-3% on AMD (09-16 relink: layout 0.95, iTLB 0.61x) | CI, ~3 h | DEAD (T4) |
| T6 | -fsplit-machine-functions full rebuild | alt code-layout lever | CI ~36 h | DEAD (T4) |
| T7 | counted click_force on famille-laptop (`PERF_KERNELS=click_force local-counted-compare.sh chromium official chs-latest`) | node vs chrome split on the exact row | jean's PC (go 2026-10-07) | try 1 INVALID (desktop contention stalled official's perf windows). Try 2 valid (i5-8350U, windows 49-51 iter each arm): wall 615.2 vs 712.7 ms (0.86x), task-clock 0.84x, insn/iter 0.92x, IPC 0.96x; chrome+musl+shims ~601 vs ~663 ms/iter, node 146 vs 226 ms/iter. Ours NOT slower; CI's ~1.01 is below the floor. CLOSED (one draw, desktop noise) |
| T8 | off-CPU trace of goto_cold on a laptop (perf sched timehist) | same as T3, if CI's perf sched is refused | laptop | needs jean's go, only if T3 blind |
| T9 | faststring AMD retune (rep stosb threshold, AVX-512 path) | ≤0.3% | CI only (no AVX-512 locally) | lowest, after T4 |

**Why:** jean wants every row ≤1.00 vs official ([[project_perf_gate_ratchet_and_parity]]);
faststring left 3 rows above. **How to apply:** update the status column as
runs land; a track is closed only by a wall-time A/B on CI or a counted
laptop run, never by a single draw ([[project_chromium_fortify_textstack_draw_lottery]]).
Related: [[project_chromium_faststring_moves_layout_text]], [[project_chromium_insn_mix_2026_10_06]],
[[project_chromium_layout_gap_is_frontend_fetch]], [[project_chromium_nav_input_local_levers_2026_10_01]].

2026-10-07 promote attempt (jean: option 1 = promote chs-fs-sha-6e56156 now,
fold #277 into the next scheduled rebuild): promote 37593198909 (EPYC 7763,
conformance 35645764121) BLOCKED by its own gate — ratchet dom_churn 184.8 vs
171.2 ms (1.079 > 1.06), parity 1.041, geomean 0.990/0.997. Textstack
dom_churn ratchet over 10 draws: 1.02 0.98 1.02 1.01 0.98 1.01 1.00 1.03 1.06
1.08 (mean ~1.02, 7763 ~1.03). dom_churn has no layout or shaping in it, so
harfbuzz/freetype cannot be on its path. chs-latest unchanged (rollback digest
sha256:7ecdcdef…6e70). jean: go 2 = investigate before promoting. Counted
dom_churn+layout_text on jean's PC, textstack vs chs-latest (kernel added
2ea945a): tmp/domchurn.log, tmp/counted-chs-fs-sha-6e56156…/. Faststring is
in the consumer Dockerfile (live since TP 37531139881), not in chs-* images.
PAUSED 2026-10-07 (jean needs the PC): counted run killed mid image build, nothing measured. Resume = `tmp/domchurn-run.sh` on jean's go.
RESUME queued 2026-10-07 (jean): waits for session ab6e2777 (directus-cms-2-46, pid 1793069) idle 2 min, then tmp/domchurn-run.sh; log tmp/wait-domchurn.log + tmp/domchurn.log.
DONE 2026-10-07 20:17 (jean's PC, i5-8350U, one draw; tmp/counted-chs-fs-sha-6e56156…/report.md): dom_churn textstack vs chs-latest wall 198.7 vs 204.2 ms (0.97x), task-clock 282 vs 282 ms/iter (1.00x), BUT instructions 1.43e3 vs 1.36e3 M/iter (1.06x), cycles 755 vs 727 M/iter (1.04x), IPC 1.02x, all +77 M/iter inside chrome-headless-shell.real (stripped, flat, no single hot address). layout_text wall 1.00x, cycles 0.87x, harfbuzz 6 ms→0. Read: textstack rebuild retires ~5% more insn on the DOM path (rebuild = different ThinLTO/PGO inlining, not text code); time cost 0-4%, under laptop noise. Matches CI ratchet mean ~1.02-1.03.
Option 2 (2026-10-07, jean "go 1 and 2 in parallel"): symbols WITHOUT a rebuild = the `chromium-link-census` GHA artifact of the build run (symtab.nm.gz = pre-strip nm; textstack run 35645764121, chs-latest = ccc8534 run 35291178853); shipped .text vaddr/size match the census exactly. perf report's hex addrs for the stripped binary = vaddr − 0x1000 (shift 0x1000 maps 100%); tmp/map-insn.py + tmp/diff-insn.py. RESULT: all 220 hot dom_churn functions (100% of mapped insn) are the SAME SIZE in both builds → identical DOM codegen; the +77 M insn/iter is spread ±10-40% per function (sampling noise at ~100 samples/fn) plus GC (cppgc marking/finalizers +). Only real build-side difference: code moved (.text +1.8 MiB, iTLB miss/MI 36.4 vs 27.4 = 1.33x). Verdict: textstack has no DOM-code regression; dom_churn 1.02-1.03 on CI = placement + draw noise. Promote re-dispatched: 37691758123.
PROMOTED 2026-10-07 ~00:1x Paris: 37691758123 (7763) green, chs-latest now 6e56156 (textstack). Gate ratchet dom_churn 181.4 vs 172.7 ms (1.05), layout 1.02, goto_cold 0.98; vs official goto_cold 1.04, dom_churn 1.03, launch/context_page 0.96. TP dispatch on main still pending jean go. Rollback digest sha256:7ecdcdef…6e70.
2026-10-08 jean "go 1, 2 and 3": (2) textstack landed on main as 83f6c07 (cherry-pick of closed #277's 6e56156, path-ignored → no CI); (1) TP 37734381973 dispatched on main (empty tags → chs-1234 = 6e56156, verified label). (3) first-text leftover is NOT the font file: laptop probe tmp/firsttext/ (fresh ctx, no-text goto, then time goto of one word, n=40 x2 rounds, median ms): ours textstack sans-serif 8.55/8.11, FreeSans.otf 8.41/8.00; ours with official's FreeSans.ttf mounted 8.25/8.11 & 8.20/8.39; official (wqy-zenhei for sans-serif) 8.35/7.91, FreeSans.ttf 7.97/8.22. → ours ≈ official within round spread (±0.3 ms); .otf vs .ttf no effect; first text at parity locally. Nothing left to chase there.

## 2026-10-08 cleanup + TP
- TP 37734381973 on main 83f6c07: completed success, so textstack shipped to consumers.
- Cleanup done: tmp/bin-*, tmp/census-*, tmp/firsttext and the six *:counted images are removed. The cip-coldsplit worktree and the local diag/cold-nav-split branch are removed; origin/diag/cold-nav-split bef12af is kept.

## 2026-10-08 gate noise: runs=5 vs runs=10 (chs-latest self-gate, 10 dispatches each)
- runs=5 (37744459406..37744529633): 5/10 red. Ratchet (identical build) breached in 3 runs: goto_cold 1.117, context_page 1.069, launch 1.067, dom_churn 1.066. Parity breached in 4 runs.
- runs=10 (37755394854..37755471894): 2/10 red. Ratchet breached in 0 runs (geomean 0.977-1.008). The only reds are parity goto_cold 1.098 and 1.093, both on 9V74.
- So 10 shots removes the self-noise. Making runs=10 the gate default is the lever; jean has not yet ruled on it.
- goto_cold vs official is a REAL residual, not noise: 18/20 runs >1.00, median 1.024 at runs=10 and 1.041 at runs=5. It matches the promote's 1.04.
- Intel 8573C layout at runs=10 reads 1.009 and 1.006, so this morning's 1.033/1.041 was noise. Layout median across runs=10 is about 1.006.
- 2026-10-08 `runs=10` is the perf-gate default, 1a9cf49 on main.
