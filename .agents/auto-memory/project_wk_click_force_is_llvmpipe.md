---
name: project_wk_click_force_is_llvmpipe
description: CLOSED 2026-10-09 by LP_NUM_THREADS=0 (fb58ffb) — CI click_force 0.937 vs official over 6 TP draws (0.90-0.98, 0/6 >1); was Mesa llvmpipe (famille insn 1.38x, CPU 1.23x); the "move the base" lever was scope drift, reverted
metadata:
  type: project
---

CI (49 shipped draws, tally cache): click_force alpine/official median 1.036,
36/49 > 1.00, every CPU model; eval_rtt 1.00, locator_click 1.00 (frame-bound).
So not the PW transport.

famille-laptop (i3-4005U, quiet, login screen only) `local-counted-compare.sh
webkit official`, PERF_KERNELS=click_force,eval_rtt,int_math, 11:34-12:01Z:
- click_force: wall 1775 vs 1503 ms (1.18x), CPU-ms/iter 4706 vs 3838 (1.23x),
  insn/iter 5.36 vs 3.87 G (1.38x), IPC 1.04x, page faults 6.7x.
- CPU-ms delta +869/iter: llvmpipe `[JIT]` +586, libgallium 407 vs 313 (+94),
  musl vs glibc +45, node +51, libWPEWebKit +23.
- ~60% of all click_force instructions are on llvmpipe-0..3 threads in BOTH
  arms: each forced click repaints and WPE composites through software GL.
- Controls: int_math 1.00x; eval_rtt CPU 1.07x (CI says 1.00).

**Why:** Mesa differs (Alpine 26.1.6 vs Ubuntu 25.2.8, built against
different LLVMs); same WebKit 26.5 / libWPEWebKit 1.10.2 both arms.
**How to apply:** open questions before any lever: more frames per click, or
heavier per frame (count llvmpipe frames / perf by symbol)? Candidate levers,
none tried: Mesa pin/rebuild, LP_NUM_THREADS, WPE CPU rendering path (skip GL).
Related [[project_wk_launch_is_mesa_in_the_closure]].

**Breakdown from the same recording (cpu-clock, 18 vs 20 iterations in window), 2026-10-08 ~14:10 Paris:**
- llvmpipe JIT samples/iter 1707 vs 1214 (1.41x); libgallium 1.24x.
- In BOTH arms one shader function (one 4 KiB JIT page) holds >90% of JIT
  time: 1621 vs 1099 samples/iter (1.47x). Its single hottest instruction is
  318 vs 298/iter (1.07x) — the extra is spread over more addresses.
- Inference (not proven): same work, HEAVIER compiled shader code, not more
  frames — more frames would scale the hottest instruction by the same 1.47x.
- Shader codegen differs: ours Mesa 26.1.6 on libLLVM 22.1, official Mesa
  25.2.8 on libLLVM 20.1. libgallium is stripped both sides (no names).
- Next discriminators: LP_DEBUG/GALLIUM frame count per click, or swap
  Mesa/LLVM in our image (Mesa built against LLVM 20) as a candidate.

**Frame count attempt, 2026-10-08 ~14:55 Paris (famille-laptop):**
- Sched data (same counted run): ThreadedCompositor wakes/iter 194 vs 362
  (0.54x), VBlankMonitor 83 vs 277 per 13 s, llvmpipe CPU per wake 2.19 vs
  0.78 ms (2.8x). So ours does FEWER compositor cycles, each ~2.8x heavier —
  NOT more frames. Coalescing vs bigger damage area: undecided.
- WEBKIT_SHOW_FPS prints nothing in our build (DEBUG=pw:browser captured
  stderr). Official arm of that run failed: the bare perf-official image needs
  `npm install -g playwright@$PW_VERSION` first (local-counted-compare does it).
- The two libWPEWebKit builds differ: official links libEGL.so.1 (glvnd) +
  libwayland-egl and has WEBKIT_SKIA_ENABLE_DDL; ours links neither, lacks DDL.
  Our Mesa tries Zink first ("ZINK: failed to choose pdev") then llvmpipe.
  An eglSwapBuffers uprobe would not compare like with like; both libgallium
  and libWPEWebKit stripped.
- Cheapest lever probe: WEBKIT_SKIA_ENABLE_CPU_RENDERING=1 on our arm.

## WEBKIT_SKIA_ENABLE_CPU_RENDERING=1 probe was REDUNDANT (famille, 2026-10-08 12:57-13:31Z)
Already shipped: Dockerfile.alpine:376 exports it in webkit pw_run.sh (PR #181,
[[project_wk_skia_cpu_rendering]]), so the 'alpine' arm had it too — `env` in the
container doesn't show it. Both arms identical, as they had to be. Compositor is llvmpipe:
JIT 1673 vs 1650 ms/iter, libgallium 390 vs 400 ms/iter (alpine vs cpu). It moves tile
painting only; compositing stays GL. click_force CPU 4439 vs 4453 ms/iter (1.00x), insn
5.07 vs 4.83 G (1.05x). vs official: 1.17x CPU, 1.31x insn (alpine); 1.18x / 1.25x (cpu).
Controls: int_math 1.00x all arms; screenshot_png_text 0.66x vs official, unchanged by env.
perf-record-report.py takes exactly 2 arms (3 => ValueError); run pairwise.
Data: famille ~/ci-prebuilds/tmp/counted-wk-cpu-render/report-*.md.
Remaining levers: Mesa 25.2/LLVM 20 candidate; WPE build diffs (libEGL/glvnd, DDL).
Official Mesa (dpkg, v1.62.1-noble): mesa-libgallium/libgl1-mesa-dri 25.2.8-0ubuntu0.24.04.2,
libllvm20 1:20.1.2-0ubuntu1~24.04.3, libglvnd0/libegl1 1.7.0-1build1.

## Track 2: build-config diff (agent, 2026-10-08; scratch tmp/track2/)
Official build script is private since PW 4f6a94b (2022); official side = last public build.sh d9e8e1e + v1.62.1 bootstrap.diff + the shipped binary.
- REVISION is the lead: ours 4d05d732 (2026-06-10); official built ~07-21 (has WEBKIT_SKIA_ENABLE_DDL: added 63f86c394b 06-11, default-on 3a7a4f74f8 06-25, removed 63929b8114 08-26; gate USE(COORDINATED_GRAPHICS)&&USE(SKIA), no cmake option).
- llvmpipe-relevant compositor commits after our base (guess they explain heavier frames): cbeeab739c opaque layers kSrc (GL_BLEND off), 3fe2ab64c4 nearest sampling, 3f959769d4 SkMipmapMode::kNone, 441a3adb23 render to renderbuffer. 48a050966d damage-only compositing gated off by default.
- libEGL/libwayland-egl NEEDED in official come via libgstgl (USE_GSTREAMER_GL=ON there, OFF ours): not a compositing factor.
- Refresh: both HeadlessViewBackendFdo SHM, VBlank = 60 Hz timer (DisplayVBlankMonitor.cpp:50-70), WEBKIT_DISPLAY_REFRESH_THROTTLE_FPS / WEBKIT_FORCE_VBLANK_TIMER; VBlank 83 vs 277 is likely a consequence of fewer frames (guess).
- Same LP thread count (4) both sides; ours ~1370 vs ~3130 wakes per llvmpipe thread per 13.3 s window.
Next lever (WITHDRAWN 2026-10-09: later-release WebKit = scope drift, [[feedback_goal_is_pw_1_62_1_browsers]]): cherry-pick those commits in prep-source.sh (or bump base to ~07-21), re-count click_force.

## Mesa/LLVM version swap — DEAD (famille i3-4005U, 2026-10-08)
Swapped Alpine 3.23 Mesa 25.2.7/LLVM 21.1 (m2523) and 3.22 Mesa 25.1.9/LLVM 20.1 (m2522) into perf-alpine:counted (tmp/Dockerfile.mesa-swap). click_force insn/iter: alpine 5.08G, m2523 5.05G, m2522 5.00G vs official 3.97G (1.27-1.28x each). CPU-ms/iter 4484 / 4328 / 4480 vs 3912. llvmpipe JIT insn 2352 / 2370 / 2365 M vs official 1673 M; libgallium 1046 / 964 / 953 vs 810 M. int_math 1.00x all.
**So:** gap is NOT the Mesa/LLVM version; our WebKit makes llvmpipe run ~40% more shader instructions (what is drawn / how: blend, sampling, mipmaps) → the 07-19 base move (commit 1df1d2e, compositor commits) is the lever. Mesa 26 doubles page faults (3040 vs 1520/iter) at no CPU cost.

## Track 4: LP_NUM_THREADS=0 is a big lever (famille, 2026-10-08 14:12-14:32Z)
click_force, same session: alpine 4609 CPU-ms/it, 1754 ms median; official 4058 / 1577; lp0 (LP_NUM_THREADS=0, llvmpipe rasterizes in-thread) 3108 / 1147 → vs official CPU 0.77x, wall 0.73x, insn 3.39 vs 3.97 G (0.85x); llvmpipe JIT 1294 M vs alpine's ~2350 M. lp2 vs official CPU 1.03x, wall 0.94x. GALLIUM_DRIVER=llvmpipe = no-op (already llvmpipe). Unvalidated on a 4-vCPU CI runner and on other kernels (screenshot/layout); i3-4005U is 2c/4t. Track 5 (WEBKIT_SKIA_CPU_PAINTING_THREADS 0/1, + lp0 replicate) launched 14:33Z.

## LP_NUM_THREADS=0 SHIPPED in pw_run.sh (fb58ffb), CI-priced (perf-gate 37793569773, EPYC 9V74, n=10)
Inverted arms: candidate = WK_LP_NUM_THREADS= (without), promoted = with; built RUN lines verified to differ. without/with: click_force 1.159, goto_warm 1.056, all others 0.987-1.013 (noise) — no row hurt. Without vs official click_force 1.031; with ≈ 0.89 (derived 1.031/1.159). Gate "BREACH" is the inversion + pre-existing libm_fmod 1.059, not a regression.

## Track 5 (famille, 2026-10-08 15:03-15:22Z): Skia painting threads DEAD, LP0 replicates
click_force CPU-ms/iter vs alpine 4476: sk0 (WEBKIT_SKIA_CPU_PAINTING_THREADS=0) 4481 (1.00x), sk1 4478 (1.00x), lp0 3132 (0.70x); official 3802.
Instructions/iter: alpine 5.08 G, sk0 5.23 G, sk1 5.30 G, lp0 3.39 G, official 3.96 G (lp0 vs official 0.86x, CPU 0.82x, wall 0.77x).
Variable did vary: SkiaCPUWorker thread present in alpine/sk1, gone in sk0. Workers are ~0.5% of samples — no lever.
Gotcha: idle gate `awk '$1<0.8'` under fr_FR mawk never passes; use LC_ALL=C (see ~/.agents/reference_mawk_fr_locale_float_compare.md).

## CLOSED 2026-10-09
TP runs 37793559783..37886691206 (after fb58ffb): click_force 0.93/0.96/0.98/0.90/0.93/0.94 vs official, median 0.937. Gap closed on the 1.62.1 tree by LP0; the 1df1d2e base move was reverted (d956f38) and is not needed for this row. See [[project_wk_residual_rows_2026_10_09]].
