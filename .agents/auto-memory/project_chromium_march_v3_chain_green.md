---
name: project_chromium_march_v3_chain_green
description: march-v3 candidate ALREADY FIXED + BUILT — 6f1e32a anchors -march beside the x64 -msse3 in compiler_cpu_abi.gn; chain 36195434477 green 2026-09-27 incl. conformance; image chs-fs-sha-6f1e32a…; COUNTED 2026-10-02: no speed (nav insn 0.99/1.01, cycles 1.01/1.02; layout_text 0.79x wall is a disturbed promoted arm)
metadata:
  type: project
---
- 35969194229 (f13ab28, -march via CFLAGS) died r7: extra_cflags land LAST on the line, override
  skcms_TransformSkx.cc's own AVX-512 -march → `_mm512_cvtph_ps requires target feature 'avx512f'`.
- e1f2c5a moved it into //build/config/compiler (anchor on -msse3) → 36191595812 failed at the anchor guard
  (chromium 151 moved -msse3 to build/config/compiler_cpu_abi.gn).
- 6f1e32a anchors on the x64 `cpu_abi_cflags += [ "-msse3" ]` (exactly 1 hit) → run 36195434477
  GREEN 2026-09-27 13:10Z: r1–r12, finalize, conformance-from-source, runtime-parity all success.
- Image: `ghcr.io/jclaveau/playwright-alpine-browsers:chs-fs-sha-6f1e32aa8b730c758602931b4002d76bd8a503e2`.
- Priced with
  `playwright/bench/local-counted-compare.sh chromium chs-fs-sha-6f1e32aa8b730c758602931b4002d76bd8a503e2 1234`.

**How to apply:** "redispatch march-v3 with the fix" = nothing to dispatch; price the existing image.
Shipping still needs the *-for-testing ruling ([[parked_for_testing_image_family]]): v3 SIGILLs pre-Haswell.

**Counted 2026-10-02 07:12-07:53Z** (`tmp/counted-chs-fs-sha-6f1e32a…/`, load 6.7 at launch), candidate vs chs-latest:
goto_cold insn 355 vs 359 M (0.99x), cycles 1.01x; goto_warm 1.01x / 1.02x; layout_reflow 1.01x / 1.03x.
layout_text wall 0.79x, cycles 0.89x BUT insn 1.08x — promoted's cycles 4.08e3 vs 3.57e3 for the same build on 10-01;
candidate's 3.62e3 matches 10-01 → the "win" is promoted's disturbed window. locator_click VOID (promoted 7770 CPU-ms/iter, 28 iters).
Verdict: march-v3 does not move nav — its whole motivation (inline memcpy) — so DEAD as a speed lever — CONFIRMED by the quiet re-run
2026-10-05 22:40-22:57Z (load 0.7-1.4, `tmp/counted-night-march-v3/`): layout_text insn 6.06e3 vs 5.92e3 M (1.02x),
cycles 1.03x, wall 0.97x; locator_click insn 2.60e3 vs 2.63e3 M (0.99x), wall 1.00x. Nothing to re-run.
