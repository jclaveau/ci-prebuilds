---
name: project_wk_residual_rows_2026_10_09
description: WebKit rows still >1.00 after LP0 (6 TP runs 37793559783..37886691206) — libm_fmod 1.057 (Zen4/5/Intel only, famille Haswell 0.96 = no local gap), js_alloc 9V45-only bimodal GC outliers (famille parity), launch 1.15 = pre-3254ba3 GST registry; click_force 0.937 closed by LP0
metadata:
  type: project
---

Rows vs official, median over the 6 TP draws after fb58ffb (LP_NUM_THREADS=0):
libm_fmod 1.057 (6/6 >1), js_alloc 1.000 (2/6: 1.23, 1.24), int_math/locator_click
1.000, eval_rtt 0.993, click_force 0.937 (0/6), everything else 0.69-0.94.

- launch 1.15 = run 37851214532 (8573C) at ac64224, before 3254ba3 (GST registry seed);
  all later draws 0.84-0.88. CLOSED.
- libm_fmod by CPU (14 TP runs): 7763 1.01-1.04, 9V74 1.04-1.07, 9V45 1.05-1.09,
  8573C 1.07. famille i3-4005U count 2026-10-09 (consumer f487901 vs v1.62.1-noble,
  same 5.1 s window): wall 307 vs 320 ms (0.96x), insn 48.2 vs 56.1 G (0.86x), cycles
  31.2 vs 34.6 G (0.90x), branch-misses 12.4 vs 10.2 M (1.21x); fastfmod 266 vs libm
  285 ms/iter, JIT 31 vs 24 ms/iter (+7). No local gap → the CI residual is a
  wide-core effect (see fastfmod.c header: glibc's longer branchless tail eats better
  on Zen4). Next lever = CI-timed candidate via wk-fastfmod-gate.yml (dispatch = jean's
  ask) or a count on jean's PC (Kaby Lake, ask first). Ours mispredicts 21% more.
- js_alloc: famille insn 90.1 vs 90.7 G (0.99x), cycles 1.00x, wall 1.01x → parity.
  CI outliers only on EPYC 9V45 (3 draws: 0.95/1.23/1.24) + one 9V74 1.16; shots are
  bimodal on BOTH sides (~85 vs ~110-125 ms; ours 5/9 high vs official 3/9) = GC
  timing. n too small to call; needs more 9V45 draws (runner lottery, CI).
- wk-lag-diagnostics run 37897201719 (main f487901, 2026-10-09, EPYC 7763): isolated
  bench fastfmod 66.3 vs glibc 64.2 ms (bench prints libc_ms/cand_ms = "0.97x libc",
  i.e. fastfmod 3% SLOWER), vs musl 63.1 vs 372.8 ms; in-browser JSC default arm ours
  vs official mod_int_double 67 vs 67 ms, mod_frac_double 87 vs 87 (1 ms clamp).
  NO transfer gap: fastfmod.c header already lists it dead (isolated transfers on
  Zen 3). The "transfer gap" was a misreading of the ratio direction: the header's
  per-core table (7763 0.94, 9V74 0.97, 6973P 0.99, 8573C 0.96) is libc/cand, so
  fastfmod is 1-6% slower than glibc everywhere, matching the 1.01-1.09 browser rows.
  Open question (header): Zen 4 eats glibc's branchless tail 38% cheaper vs our 20%;
  needs PMU counters on a runner. Data: tmp/wk-lag-37897201719/.
Data: famille ~/ci-prebuilds/tmp/counted-official-webkit/ (libm_fmod, js_alloc files
dated 10-09 08:2x; click_force/eval_rtt/int_math files there are from 10-08).
Related: [[project_wk_fastfmod_ships]], [[project_wk_click_force_is_llvmpipe]].
