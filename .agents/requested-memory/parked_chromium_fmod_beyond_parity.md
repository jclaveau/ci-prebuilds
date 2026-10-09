---
name: parked_chromium_fmod_beyond_parity
description: RESUMED 2026-10-09 on jean's ask (lever 1, PR #333 stacked on #332, run 37927026157); was PARKED as BEYOND PARITY — chromium using the WK/FF fmod (hybrid); official chromium also uses inline x87 fprem, so no gap to close; needs a V8 kSSEFloat64Mod patch + a ~25-30h cold rebuild
metadata:
  type: project
---

Ruling 2026-10-09: "regarding chr file it as beyond parity".

Two separate levers, neither started:
1. JS `%` — V8 15.1 x64 emits inline `fprem` (code-generator-x64.cc
   kSSEFloat64Mod) in every tier, no call. Hybrid needs a V8 patch to call
   a C function instead. Zen 3 says yes (fprem 15.5 vs hybrid 7.0 ns at gap
   11, EPYC 7763, run 37910052122); Intel says no (earlier microbench on
   i5-8350U: our code 2.8x slower than fprem).
2. The 95 static `fmod` call sites = Rust compiler_builtins fmod linked into
   chrome (no libc import, LD_PRELOAD can't reach). In FF libxul that symbol
   is WEAK, so linking a strong hybrid.o overrides it; chromium's binding
   unchecked. None of these sites is on a measured hot path.

**Why parked:** official chromium uses fprem too → libm_fmod already at
parity; campaign goal is conformance + >= parity
([[feedback_goal_is_pw_1_62_1_browsers]]).
**How to apply:** resume only on jean's ask; measure per microarchitecture
first (fprem cost flips Intel vs Zen). See
[[project_fmod_everywhere_preload_vs_patched_musl]].

**RESUMED 2026-10-09 (lever 1 only)**, jean: "as a stacked pr, plz dispatch
a build of a patched chr using libm-fmod-custom".
- Branch perf/chr-libm-fmod-custom 7837189, draft PR #333 → base
  perf/fmod-fprem126 (draft PR #332 → main). Neither merged.
- Design: x64 gets the arm64 shape. TurboFan kSSEFloat64Mod and Maglev
  Float64Modulus now call mod_two_doubles_operation (the same pattern as
  Ieee754Binop and Exponentiate). Modulo() in utils.h calls
  v8_libm_fmod_custom: gcc -S with -Dfmod=v8_libm_fmod_custom, put in
  v8_libbase as a .S file.
- Script: chromium-headless-shell/scripts/v8-libm-fmod-custom.py. Every
  anchor must match exactly once. Dry run on V8 f479186c applied all 7 patches.
- Dispatch run 37927026157 (cold, ~25-30h). The branch build moves
  chs-fs-edge. Promote is refused off main.
- Next: chs-perf-ab vs shipped, on BOTH Intel and Zen (fprem flip). Needs a go.

**GO given 2026-10-09 ("go 1, 2, 3"), gated on the builds:**
1. When chromium 37927026157 is green: perf-gate dispatch, ref
   perf/chr-libm-fmod-custom, browser=chromium, candidate=its chs-fs-sha tag,
   promoted=chs-latest, rev=1234, runs=10; twice-or-more until one Intel and
   one Zen draw (fprem flip).
2. When firefox 37925571320 (perf/fmod-fprem126, sha 3323d08) is green:
   perf-gate dispatch, browser=firefox, candidate=its sha tag,
   promoted=ff-latest, rev=1538, runs=10.
3. Second fmodf preload A/B: perf-gate 37936829426 (same args as 37933876301).
