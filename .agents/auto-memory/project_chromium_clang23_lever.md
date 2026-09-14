---
name: project_chromium_clang23_lever
description: clang 22→23 IS a layout lever — MEASURED 2026-09-13 layout 0.96 (fast runner) / 0.87 / 0.87 (slow runner, separated) vs the shipped PGO+ThinLTO build, vs official layout 1.40 and geomean 1.10 (was 1.61 / 1.12); alpine:edge packages clang23 23.1.1 since ~2026-09-10 so the self-built chs-clang toolchain image is superseded; the chain needed two build fixes (busybox sed no-op, sanitizer headers)
metadata:
  type: project
---

**The candidate.** `perf/chromium-clang23` @ `80ea0bc`, artifact
`chs-fs-sha-80ea0bc05ba05f79b5e6767595d6403ffbe8911f` (run 34652798588, 12/12
rounds, conformance 20/20; the run's only red was the parity gate counting a
flaky retry as a loss — [[project_conformance_parity_flaky_is_pass]]).
`apk add clang23 clang23-dev lld23 llvm23` on alpine:edge, `CHS_LLVM_VER=23`
read by apply-and-build.sh ahead of aports' `_llvmver=22`. Same Alpine driver
patches as the clang22 control, so the compiler major is the single variable —
which the self-built `ghcr.io/jclaveau/chs-clang` image (Dockerfile.clang,
PR #203/#204) could not claim, since it dropped those patches. That image and
`chromium-clang-toolchain.yml` are now unreferenced; jean decides their fate.
Host tools build on clang23 too, without LTO (`5da5bed`, the fix for four
lld crashes on host codegen plugins).

**Against the shipped build** (`chs-1234` = `d4e5f6b`, PGO+ThinLTO), three
`chs-perf-ab` runs, candidate/shipped, n=3 on layout:

| run | order | runner (`libm_fmod` ms) | layout | goto_warm | dom_churn |
|---|---|---|---|---|---|
| 34761461504 | shipped→c23 | 141 | 0.96 overlap | 0.99 | 0.98 |
| 34761644615 | c23→shipped | 171 | **0.87 SEPARATED** | 0.94 | 0.92 |
| 34761780624 | shipped→c23 | 171 | **0.87 SEPARATED** | 0.96 | 0.94 |

Same direction three times; the gain is larger on the slower silicon, which is
where the layout gap is worst ([[project_three_model_parity_state]]). Run 1's
screenshot 0.79 and click_force 1.08 did not survive the bracket (1.00 / 0.99)
— frame-quantized rows, ignore.

**Against official** (run 34761950633, slow runner, ours/official):
layout **1.40** (was 1.61), goto_warm 1.26, launch 1.18 (this candidate
predates the DSO trim; with [[project_chromium_launch_dso_closure]]'s 0.79x it
projects to ~0.93), click_force 1.19, goto_cold 1.15, eval_rtt 1.19,
dom_churn 0.98, screenshot 1.03, controls 1.00. **Geomean 1.10** over all 13
rows (was 1.12), 1.17 over the eight rows that move.

**Two build blockers, both invisible until hours in:**
- `sed '0,/re/'` in the `<cstdlib>` insert is GNU-only; busybox exits 0 and
  does nothing, so `third_party/libxml/chromium/xml_reader.cc:22 'free'` failed
  on every round while the setup log said `+<cstdlib>` (run 34576352942). Now
  awk + a grep assertion (`773cea1`).
- `v8/src/sandbox/testing.cc` includes `<sanitizer/common_interface_defs.h>`
  unconditionally; a compiler-rt built with `COMPILER_RT_BUILD_SANITIZERS=OFF`
  drops the headers with the runtime. The packaged compiler-rt ships them.
  clang22 on main had the same hole for a different reason —
  [[project_chromium_compiler_rt_move_breaks_clang22]].
- `lld22` and `lld23` both provide `cmd:ld.lld`; apk refuses the pair. The
  branch drops lld22 and links a ThinLTO hello world at setup (`80ea0bc`).

**How to apply:** clang23 is the new base for every further chromium
candidate (SSP-via-cfg, textstack, …) — measuring on clang22 now measures a
compiler nobody will ship. Shipping it = rebase `perf/chromium-clang23` onto
main (unbundle #222 + sanitizer #223 are there), ~38h build, promote via
`promote-chromium-from-source.yml` on main. Jean's call.

**SHIPPED 2026-09-14/15.** `4362396` (the branch merged with main) went
12/12 + conformance 20/20 + parity green (run 34763050768), A/B vs official
on EPYC 9V74 (run 34900570958, official/ours): layout 0.84, goto_warm 0.84,
click_force 0.87, launch 1.30 n.s., every control 1.00. PR #243 merged
(76df63f), promote 34902520647 retagged `chs-fs-sha-4362396…` → chs-1234 /
1.62.1 / latest, consumer rebuilt by test-and-publish dispatch 34906092917.
Residual vs official on this runner: layout/goto_warm 1.19×, click_force
1.15×; the flags + libc candidates chase it from this base.
[[project_chromium_residual_gap_candidates]] [[project_chromium_perf_arms_1_62]]
