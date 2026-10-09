---
name: project_fmod_everywhere_preload_vs_patched_musl
description: fastfmod image-wide (preload everywhere vs musl libc.so rebuilt with it) buys ONLY WebKit — FF fmod is a private Rust compiler_builtins copy in libxul, V8 never calls libc; musl's own CFLAGS_AUTO costs a rebuilt fmod 4%, per-file flags (cand2b) fix it
metadata:
  type: project
---

2026-10-09, famille (i3 Haswell 1.6 GHz), `libm_fmod`, 3 candidates vs stock
consumer image (which already preloads fastfmod for WebKit only):

- cand1 = `libfastfmod.so` added to container-wide LD_PRELOAD + CHS_LD_PRELOAD + FF wrapper
- cand2 = Alpine's musl-1.2.6-r2 APKBUILD rebuilt with `src/math/fmod.c` = fastfmod (union punning, `-ffreestanding`), WK preload removed
- cand2b = cand2 + Makefile fragment `obj/src/math/fmod.{o,lo}: CFLAGS += -ftree-ch -falign-loops -falign-jumps -falign-labels -falign-functions -freorder-blocks-algorithm=stc -fira-region=mixed -fno-ira-hoist-pressure`

Results (median wall, ours vs stock):
- isolated vectors: stock musl 305 ms, preload 97.5, cand2 99.7, cand2b 97.4; all bit-exact (same output sha, checksum)
- webkit: cand1 307 vs 307 (1.00x), cand2 319 vs 307 (1.04x), cand2b 307 vs 307 (1.00x)
- firefox: 491 vs 491 (1.00x) both; chromium 128.6 vs 128.6 (1.00x) both

Why cand2 lost: musl `configure` sets `-O2 -fno-align-* -freorder-blocks-algorithm=simple -fno-tree-ch` for everything outside internal/malloc/string (Alpine keeps it, strips only -O). fmod loop not rotated (extra `jmp` per iteration) + two `bts;jmp` on the normal path. cand2b's fmod disassembles IDENTICAL to libfastfmod.so (525 B, 137 insn).

Why FF/CHR don't move:
- libxul imports no `fmod` (only fmodf, remainder). It has a LOCAL `t fmod` → `compiler_builtins::math::libm_math::fmod` (Rust libm's generic fmod: `div` fast path + `linear_mul_reduction`, NOT musl's bit loop); `js::NumberMod` calls it at insn 2; 57 call sites. Official FF also imports none → parity. Only lever = relink libxul with fastfmod.o (beyond parity, untested). Newer SpiderMonkey has an int64 fast path in NumberMod; our build lacks it.
- V8 15.1 x64 lowers double `%` to inline x87 `fprem` (kSSEFloat64Mod) in every tier; int32 path only when both operands are int32. Chromium kernel is ~24 cycles/iter (perf-kernel.cjs = 9M iterations, the old "~6" divided by 36M) = fprem. Chromium also links a static Rust fmod (95 sites). Parked beyond parity: [[parked_chromium_fmod_beyond_parity]].

Other libc-fmod users in the image (scanelf, 34): WebKit, node, FF's bundled ICU/sqlite/avutil, gtk/cairo/xml/python/perl/sqlite… none on a measured hot path. List: tmp/fmod-everywhere/bins/fmod-users.txt.

FF's Rust fmod vs ours (2026-10-09, famille, same `vectors` binary, preload each). Alpine 3.24 rustc 1.96.1 compiler_builtins fmod disassembles IDENTICAL (164 insn) to libxul's (built with 1.98.1); extracted from the rlib into tmp/rustfmod/librustfmod.so on famille. Cycles per call, bit-exact everywhere:
- narrow exponent gap (kernel `i*2654435761 % 4294967291`, 15M calls): musl 164 / ours 51 / Rust 79 cycles; insn 252 / 79 / 219 → ours 1.53x faster (96.5 vs 147.7 ms)
- random full-range bit patterns (gate's correctness stream, 7.5M calls): musl 2160 / ours 687 / Rust 244 cycles; insn 2020 / 618 / 437 → Rust 2.8x faster (linear_mul_reduction beats our 11-bit-per-div loop on wide gaps)
Rust libm is MIT/Apache (port-safe, unlike glibc LGPL): a hybrid (ours for small gaps, Rust's reduction for wide) would win both.

Hybrid + fprem126 (2026-10-09; branch perf/fmod-fprem126 2edb8d9, candidates/hybrid.c = ours ≤33-bit gap, Rust linear_mul_reduction above; fprem126 = x87 fprem ≤126 then Rust). All bit-exact everywhere.
- famille Haswell: fprem126 wins every gap (gap 11: 17.7 vs ours 33.1 ns); WebKit libm_fmod kernel fprem126 185 vs base 307 ms (0.60x), hyb33 314 vs 307 (1.02x).
- CI run 37910052122 (8 draws, no PMU): fprem126 LOSES on every runner CPU, kernel bench vs shipped: 7763 169.2 vs 62.9 ms (2.69x), 9V74 148.2 vs 44.1 (3.36x), 9V45 75.8 vs 35.3 (2.15x), 8370C 95.5 vs 59.0 (1.62x). fprem is fast only on Haswell. hybrid: 1.01-1.06x at narrow gaps, gap 100 14.3 vs 31.8 ns, gap 2000 57.7 vs 646.4 ns (7763).
- glibc at gap 11 still beats shipped (9V45 2.7 vs 4.3 ns) = the 1-6% residual.
- Rust fmod in libxul is WEAK (`W fmod`, compiler_builtins cgu.262) → a strong hidden-visibility fmod object in the libxul link overrides it; LTO inlining unverified.

Unified candidate (2026-10-09, famille Haswell, scratch hcold/unified3.c, bit-exact 0 mismatches): glibc-style d≤11 single-div prologue + d 12-22 two 64/64 divs + d 23-63 one inline 128/64 `divq` + d>63 Rust reducer. ns vs glibc: gap 0 20.7 vs 31.4, 5/11 28.2 vs 27.4 (1.03x), 21 40.4 vs 52.4, 32 64.3 vs 60.6 (1.06x), 44 64.7 vs 69.3, 64 86.7 vs 83.5 (1.04x), 100 86.8 vs 113.0, 2000 202.9 vs 1394.6. Beats shipped + Rust at EVERY gap. Haswell 128/64 divq ~100 cycles flat (gap 21 via divq 62.8 ns vs two divs 40.4) — Zen expected far cheaper, unmeasured.

Unified on CI (run 37914586575, 8 draws, branch perf/fmod-fprem126 aa71182, candidates/unified.c, 0 mismatches vs musl AND glibc). Kernel bench unified vs glibc: 7763 53.3 vs 64.2 ms (0.83x), 9V74 0.86x, 9V45 0.87x, but Intel 8573C 1.01-1.02x, 6973P 1.03x (shipped there 1.04-1.06x). Sweep: beats glibc at every gap ≥16 on every CPU (0.09-0.83x); gap 5-11 parity ±4%; gap 0 LOSES on Intel/9V45 (8573C 7.6 vs 7.0 ns, 1.09x). vs Rust in the same musl container: wins every gap, every CPU (gap 2000 7763 58.0 vs 76.0 ns). Same unified.c is ~25% slower at gaps ≥500 when built by noble gcc vs Alpine gcc (7763 gap 2000 78.0 vs 58.0) = codegen of fmod_wide, matters for the clang libxul build.

unified7 (branch 9bbdebf, famille, 0 mismatches). Two fixes:
- Trailing-zero fold: s = min(d, tz(y)); `(mx<<d)%my == ((mx<<(d-s))%(my>>s))<<s`, one 64/64 div while d−s ≤ 11. Kernel divisor 4294967291 has 21 trailing zeros, which covers gaps 19-23. Kernel: unified3 436.3 / unified5 289.5 / glibc 307.6 ms. A branchless equal-exponent block (unified6) gained nothing (296 vs 289), dropped.
- clang: `memcpy` in to_bits/to_double under musl fortify-headers made clang emit a stack canary plus a pointer-overlap compare chain per call. Instructions: gap 0 86 vs 35, gap 11 112 vs 54. `__builtin_memcpy` removes both.
  - After the fix, clang beats gcc at gaps ≥150 (gap 2000 186.6 vs 203.0 ns).
  - Kernel: clang 303.8 vs gcc 289.1 ms. The whole delta is clang's `idivq-to-divl` bypass (or/shr/je before each div). With `-Xclang -target-feature -Xclang -idivq-to-divl` clang gives 292.1 ms.
  - Matters for the libxul build: per-file flag, or accept it (divq is cheap on Zen and recent Xeon).
- The CI sweep now also builds unified-clang.so (Alpine apk adds clang). It is not dispatched yet.

unified7 on CI (run 37916504785, 9bbdebf, 8 draws: 7763 ×5, 8370C ×2, 8573C ×1, 0 mismatches). Data in tmp/unified7-ci.
- Kernel, unified vs glibc: 7763 51.8 vs 64.3 ms (0.81x); 8370C 54.4 vs 60.4 ms (0.90x); 8573C 48.0 vs 55.2 ms (0.87x). The 8573C was 1.01-1.02x slower before the fold, so the Intel kernel residual is closed.
- Remaining losses vs glibc: gap 0 on 8573C 8.1 vs 7.8 ns (1.04x); gap 5-11 on 8573C 4.0 vs 3.9 ns (1.03x). Everything else is at parity or faster.
- Firefox-relevant comparison is Alpine clang build (`alp-clang`) vs Rust, same container.
  - Wins every gap on 7763 and 8370C (7763 gap 2000 51.7 vs 75.3 ns).
  - 8573C: gap 64 14.9 vs 14.8 ns (parity); gap 500 26.6 vs 22.5 ns (1.18x SLOWER; Alpine gcc build is 18.3).
  - clang vs Alpine gcc at gaps 5-11: 5.1 vs 4.4 ns on 7763 and 4.7 vs 4.0 on 8573C, so clang also loses to glibc there (1.06-1.21x). Suspect: clang's idivq-to-divl bypass (measured on Haswell kernel, unmeasured on runner CPUs).

clang without idivq-to-divl on CI (run 37919147875, fd02a04, per-gap microbench, 8 draws: 7763 x4, 9V74 x2, 9V45 x2, no Intel; 0 mismatches). REFUTED on runner CPUs: `alp-nodivl` reads the same as `alp-clang` at every gap (7763 gap 5 5.1 vs 5.1 ns; gap 500 24.5 vs 25.0). The bypass explains the Haswell kernel delta only.
- clang vs Rust, same container: wins every gap on all 3 CPUs (9V74 gap 0 6.3 vs 7.2 ns, gap 500 20.6 vs 24.7, gap 2000 44.3 vs 66.6).
- clang vs Alpine gcc: slower at gaps 5-55 (7763 gap 26-55 6.4 vs 5.3 ns, 1.2x), faster at 2000 (51.8 vs 57.5). Cause unknown; next is a gcc-vs-clang asm and insn-count diff of the d<=11 and d 23-63 paths (local, famille).
- noble gcc unified vs glibc: 9V74 gap 5/11 3.6 vs 3.3 ns (1.09x), 9V45 gap 0 6.4 vs 6.1 (1.05x). The narrow-gap residual is not Intel-only.
- 8573C gap 500 (clang 26.6 vs Rust 22.5 ns) was not re-drawn this run.

clang codegen diff (famille Haswell, Alpine gcc vs clang, PMU counts, 2026-10-09):
- Real cause of clang's mid/wide-gap cost: the divq asm's `"rm"` divisor constraint. clang picks memory (`mov [rsp-8],r8; div QWORD PTR [rsp-8]`), a store-forward before the divide. `"r"` fixes it: cycles gap 32 109.4 -> 103.1 (gcc 103.8), gap 64 146.8 -> 141.6 (gcc 144.1), gap 500 178.3 -> 173.9 (gcc 179.6). gcc unchanged. Branch 31e1407, bit-exact (vectors sha + per-gap microbench).
- Gap 5-11: clang +1 insn, +1.5 cycles vs gcc. Host gcc vs glibc 2.41: 53 vs 56 insn but 44.7 vs 43.6 cycles (latency, not work). Shifting the dividend instead of the divisor (`(mx53<<d)%my53`, unified9) changed nothing (44.5). Dead; the 1-cycle residual is unexplained.
- Haswell's 128/64 divq makes gap 26 lose to glibc locally (101 vs 95.5 cycles); runners show 0.34-0.41x, so Haswell-only.

`"r"` fix on CI (run 37920769167, 9ea1958; 7763 x4, 9V74 x2, 9V45, 8573C; 0 mismatches):
- clang mid gaps shrink: 7763 gap 26 6.4 -> 6.0 ns, gap 500 25.0 -> 23.1, gap 2000 51.7 -> 49.6 (gcc 5.3 / 21.9 / 57.6). Gap 5-11 unchanged (7763 5.1 vs gcc 4.4).
- clang vs Rust: wins every gap on 7763/9V74/9V45 (7763 gap 500 23.1 vs 28.8 ns, 0.80x). 8573C still loses gap 250-1000: gap 500 21.1 vs 18.7 ns (1.13x, was 1.18x), gap 1000 32.0 vs 29.9 (1.07x); wins gap 2000 40.0 vs 56.3. gcc on 8573C gap 500 is 15.3, so clang's Intel wide-gap loop still costs ~1.4x gcc.
- kernel unified vs glibc 0.81-0.87x, shipped vs glibc 1.02-1.08x.

Intel wide-gap diff (local, 2026-10-09): the 8573C clang loss repeats across runs (gap 64 clang vs gcc 14.9 vs 10.7 ns in 37916504785, 11.4 vs 8.9 in 37920769167) but the code does not explain it. Alpine clang 22.1.3 and Ubuntu clang 20 emit the same wide_reduce: loop unrolled x2 behind a divide-by-63 parity prologue (`imul 0x4104105`, `bt edx,5`), same mul->add chain as gcc; fmod_wide is identical. llvm-mca on the gap-500 path (8 iterations) predicts clang FASTER: sapphirerapids 97 vs 108 cycles/call, znver3 85 vs 86, haswell 182 vs 200; Haswell measures it too (173.9 vs 179.6). So the cost is dynamic (frontend/alignment/predictor), invisible without an 8573C PMU. Alpine gcc's build beats Rust at every gap on all 4 CPUs (8573C gap 500 15.3 vs 18.7 ns, 7763 gap 2000 57.6 vs 75.2), so the clean fix is linking a gcc-built unified.o into libxul instead of tuning clang.

gcc vs clang22 on CI (37920769167): gcc wins gaps 5-64 everywhere and 64-1000 on 8573C (gap 500 15.3 vs 21.1 ns); clang wins only gap 2000 (~1.15x). BUT every clang/Rust number above is the WRONG toolchain: the microbench ran in alpine:3.24 (bare `apk add clang` = clang22, 3.24's rust) while the Firefox builder is alpine:edge clang23 + rustc 1.99. clang23 emits no imul/bt prologue in wide_reduce, so "gcc beats clang for libxul" is UNPROVEN. gcc route for libxul was prepared but NOT written (gcc absent from edge builder; `.s` from gcc goes in SOURCES, mozbuild assembles via clang). fef7637 (branch perf/fmod-fprem126) moves clang+Rust rows into an alpine:edge container (`edge.txt`), 8 draws dispatched, results land in tmp/clang23-ci; decision rule: clang23 beats Rust + matches gcc on 8573C -> drop gcc route, keep mach-compiled unified.c; else apply gcc edit. Local Haswell edge check: clang23 <= gcc at every gap, 0 mismatches. Firefox libxul build (76fed49 wiring: unified.c COPY + step 6a + linker-map check that fails if fmod not ours/exported) NOT dispatched: needs its own go; cold PGO build, and a branch dispatch of build-firefox pushes `sha-<sha>` AND moves `edge`, which promote-firefox promotes by default (promote by sha- tag or stop branch builds moving edge).

clang23 RESULT (run 37922755468, 8 draws: 4x 7763, 3x 9V74, 1x 9V45, no 8573C, 0 mismatches): clang23 beats Rust 1.99 at every gap (0.04-0.88x) but trails edge gcc 15.2 at gaps 5-1000 (up to 1.17x, gap 1000 9V45 24.6 vs 21.0 ns); clang23 misses glibc at gaps 0-11 (1.01-1.10x), gcc does not (7763 gap 5 4.4 vs 4.7 ns). Haswell's clang23<=gcc does NOT hold on servers. gcc route APPLIED 2d21acb: Dockerfile stage `fastfmod-gcc` (edge gcc -O2 -fPIC -fvisibility=hidden -S) COPYs only the .s into the builder (builder apk list untouched); step 6a puts `fastfmod-unified.s` in js/src SOURCES; clang23 assembles it to GLOBAL HIDDEN fmod + .note.GNU-stack (checked locally). Firefox dispatch still needs its own go.

RENAMED 2026-10-09 (3323d08): `fastfmod` → `libm-fmod-custom` (dir out of
webkit/, unified.c → libm-fmod-custom.c, old bit-loop → candidates/fastfmod.c);
gate `libm-fmod-custom-gate.yml` adds Firefox's form (gcc -S, clang-23 assembles),
green locally; WebKit preload on the branch now builds from the unified source.

**Why:** answers "use fastfmod instead of musl's everywhere?" — no browser gain beyond WebKit, which already has it.
**How to apply:** don't re-run cand1/cand2 for browser perf. If libc fmod is ever replaced, use the cand2b flags. Counter caveat: identical code read 1.06x instructions here — perf's sharing of counters across many events on this harness makes ±7% instruction ratios noise; trust wall + task-clock. See [[project_wk_fastfmod_ships]], [[project_wk_residual_rows_2026_10_09]].

**fmodf for chromium, 2026-10-09** (per-gap microbench on famille-laptop i3-4005U; scratchpad fmodf/gapf.c).
chrome-headless-shell and libvk_swiftshader import `fmodf` from musl. They import
no `fmod`: the double calls bind inside the binary to compiler_builtins.
- musl fmodf is a bit loop, about 7 ns per bit of gap: 22.5 ns at gap 0, 304 ns at 40, 1713 ns at 250.
- glibc 2.39 (noble) is about 1 ns per bit: 17.0 ns at 0, 62.0 ns at 40, 270 ns at 250.
- `(float)fmod((double)x,(double)y)` through libm-fmod-custom is exact: 0 of 20M
  random bit patterns differ, on both libcs. It costs 15.6-17.1 ns flat for gaps 0-48,
  then 55-166 ns on the wide path. It beats glibc at every gap.
- A dedicated integer fmodf (40-bit chunks) is slower than via-double up to gap
  48 and slightly faster at 64-200.
Not yet known whether any chrome fmodf call site is hot.
- Callers (chs-latest 6e56156; PLT b31d450 found by disassembly, named from
  the link census symtab of run 35645764121, whose .text addresses match the
  stripped binary): 66 sites in 42 functions.
  - canvas arc/ellipse
  - Skia dashing: CalcDashParameters, clip_line, cull_line
  - color hue/HSL
  - CSS calc round/mod/rem stepped values
  - gradient angle, offset-path, tab width
  - skottie
  - xnnpack/tflite ModulusOp
  These are per-draw or per-style calls, with no inner loop. Angles mod 2π have
  small gaps (musl 22-46 ns vs via-double 15.6 ns), so a call saves about
  10-30 ns.
- **CI runner draws, run 37929140939** (branch perf/fmodf-microbench cbafae5; 8
  draws: 7763 ×5, 9V74 ×1, 8573C ×2; no PMU). These REVERSE the Haswell
  ranking: the runners' fast 64-bit divide makes the dedicated integer
  fmodf-custom (gcc) the winner. Every candidate is exact: 0 of 20M random
  bit patterns differ, on every draw and both libcs.
  - fmodf-custom-gcc vs musl: 0.58-0.70x at gap 0, then 0.02-0.19x
    (7763, gap 40: 4.9 vs 154.4 ns).
  - fmodf-custom-gcc vs glibc 2.39: 0.98-1.11x at gaps 0-8 (about 0.4 ns), then 0.13-0.51x.
  - via-double LOSES to glibc at narrow gaps: 1.5-3.9x (7763, gap 8: 15.2 vs 4.4 ns).
  - clang23 build of fmodf-custom vs the gcc build: 1.03-1.33x → ship the gcc build.
  - On Haswell (i3-4005U) the slow divide makes custom 28 ns vs glibc 15 ns at gaps 3-8.

**fmodf tuned + wired, 2026-10-09** (PR #334 draft → base perf/fmod-fprem126, branch perf/fmodf-microbench 1af43de):
- `libm-fmodf-custom.c`, a SEPARATE source in the same .so. It is not in libm-fmod-custom.c because FF libxul and V8 (#333) link that file, and a new global fmodf would change those builds.
- Fast paths when ey >= 24: a 32/32 divide for d <= 8, one 64/64 divide for d <= 40.
- i3-4005U, tuned vs glibc: gap 0 14.9 vs 17.0 ns (0.88x); gaps 3-8 16.3 vs 15.1 ns (1.08x, was 27.9).
- Gate: classes 6-9, 4,001,156 fmodf calls, a brokenf twin. Each path mutated alone is killed. `ay<=INF` → `<` is an equivalent mutant.
- CHS_LD_PRELOAD default is now faststring:libm-fmod-custom; the runner mirrors it.
- CI microbench: run 37931118190.
- **CI 37931118190 result (8 draws: 9V45, 7763 x2, 9V74 x3, 8573C, 6973P-C)**: the narrow-gap path does NOT help on CI CPUs.
  - Tuned vs glibc at gaps 0-8 is 1.00-1.17x, about the same as the old custom's 0.98-1.11x. It is slightly worse on Zen 4/9V74 (3.6 vs 3.4 ns) and slightly better on the Intel parts.
  - Gaps 12+: 0.14-0.59x vs glibc.
  - vs musl: 0.02-0.70x everywhere.
  - Mismatches: 0.
  - Only Haswell gains (gaps 3-8: 1.85x → 1.08x vs glibc), because 64-bit div is slow there.
  - The gate on the PR (37931120527) is green.
- **Ruling 2026-10-09 (jean): KEEP the tuned fmodf.** jean said: "keep the custom for fmodf as i may use the famille laptop for hosted runners".
  - **Why:** Haswell (i3-4005U) may become a self-hosted runner. There, the 32-bit path takes gaps 3-8 from 1.85x to 1.08x vs glibc. On the GitHub CI CPUs it is neutral (±0.2 ns).
  - **How to apply:** don't revert the narrow-gap path over a sub-ns loss on the newer EPYCs. Weigh Haswell as a target CPU in later fmod/fmodf tuning.
- **Live counter check, famille-laptop, 2026-10-09**. Setup:
  - image: jclaveau/alpine-dood-playwright:latest;
  - `CHS_LD_PRELOAD=counter:libm-fmod-custom.so:faststring`;
  - workload: 5 setContent+screenshot of a page with canvas arc/ellipse/setLineDash ×200, color-mix/oklch/hsl hues, CSS mod/rem/round, gradients, offset-path, tab-size.
- Result:
  - The counter loaded in the browser, both zygotes, the utility process and the renderer. dladdr shows fmodf's next symbol is /count/libm-fmod-custom.so, so the preload does bind.
  - All calls come from the RENDERER: 1600-1663 (751 x<y, ~849 gaps 0-8, 0 at gap 9+).
  - Browser, zygote and utility: 0.
- Expected saving at about 30 ns per call: about 50 µs over 5 loads. Real but tiny in wall time.
- Gotcha: chrome rewrites a zygote child's /proc/self/cmdline (no NUL separators), so parse `--type=` with strstr rather than per-argv. Children _exit, so dump periodically, not in a destructor.
- Scratch tooling lives at scratchpad/fmodf-count and ~/fmodf/count on the laptop.

**fmodf preload CI A/B, 2026-10-09 — FLAT.** perf-gate 37933876301 on
perf/fmodf-microbench, chs-latest both arms, candidate_build_args
CHS_LD_PRELOAD=/usr/lib/libfaststring.so (without) vs branch default
(+libm-fmod-custom.so, with); env lines verified per arm; EPYC 9V45, 10 shots.
With vs without: geomean ~1.01x, every row 0.999-1.041x, all inside cv
(dom_churn 115.0 vs 110.5 ms cv 0.059, goto_warm 150.7 vs 145.5 ms cv 0.075);
libm_fmod 321.6 vs 321.4 ms (JS % = V8 fprem, never fmodf). Ratchet table
(without/with) geomean 0.990, all green. Matches the ~1,600-call count: no
wall effect. Kept per jean's ruling (Haswell hosted-runner case).
Second draw perf-gate 37936829426, EPYC 7763 (Zen 3 again, no Intel): with vs
without geomean ~1.00, rows 0.974-1.012x (dom_churn 172.9 vs 177.4 ms, layout
147.9 vs 146.7 ms), ratchet geomean 1.001. Earlier draw's "with" lean did not
repeat = noise. FLAT on both Zen draws.

**FIREFOX libxul fmod RESULT, 2026-10-09** — build 37925571320
(perf/fmod-fprem126 3323d08, PR #332) all green: conformance-firefox 20/20,
runtime-parity, smoke; promote-firefox skipped (branch). Its own
perf-gate-firefox, EPYC 7763, 10 shots: libm_fmod new 271.0 vs shipped
925.5 ms (0.293x), vs official 1252.5 ms (0.216x). Ratchet geomean 0.910
(only libm_fmod moved; goto_cold 0.950, rest 0.99-1.02 inside cv);
parity geomean 0.706. Only one CPU draw (Zen 3); Intel not yet seen.

**musl libc-test on libm-fmod-custom, 2026-10-09 — PASS** (local alpine:edge,
libc-test 7b95dfa, src/math/fmod.c + fmodf.c: sanity 10 + special 66 + ucb
tables each, checks result bits AND fp exceptions via fetestexcept). Pass for
musl, custom .so fmod + fmodf (main 3f06490 + #334's fmodf), and Firefox form
(gcc -S, clang-23 assembled). Controls bite: value-corrupted fmod 19 fails,
fmodf 67; special path returning NaN without FE_INVALID 136 fails each.
So (x*y)/(x*y) raises INVALID correctly. Not yet in the gate (needs a go).
Scripts: scratchpad libctest/run/{run,neg}.sh.

## 2026-10-09 late: libc-test in gate, fmodf into libxul, who imports what
- libc-test step in gate landed 9ed9ca7 (green 37986016376); #334 rebased (3e9227b, 446b278) gate green 37986308115 with fmod+fmodf, controls 17/136 and 19/136.
- Scan of exported wk/ff/chs-latest images (`FROM scratch`: export tree, host `nm -D`): all three import musl `fmodf`. Today's preload covers fmod only; after #334 WebKit + chromium get our fmodf, Firefox did not (libxul imports it, no preload under FF).
- Commit 2a67bcf on #334: fmodf linked into libxul like fmod (Dockerfile gcc -S, apply-and-build.sh sources); build asserts libxul's fmodf is local and not imported/exported. Untested in real FF build (multi-hour, dispatch needs a go).
- Gate gap fixed: Firefox-form check had no fmodf, so it compared musl fmodf to itself and could not fail.
- libm-fmodf-custom.c stays a separate file: V8 links libm-fmod-custom.c with fmod renamed; an fmodf there would hijack chrome's fmodf.
- WebKit/FF fmodf hot-path value never profiled.

## #334 deep review + fmodf trick audit (2026-10-10)
- Review of 2a67bcf: no HIGH/MED; fmodf bit-identical to musl on 612.8M inputs (NaN bits too). Only diff: x86 denormal-operand flag (0x2) not raised when subnormal x gives ±0 (musl does `0*x`); same pattern already in fmod. Document in header, don't pay for `0*x`.
- via-double candidate rows are SUSPECT: `candidates/fmodf/run-gapf.sh` dlopens RTLD_LOCAL without -Bsymbolic, so its fmod call hits libc's PLT fmod, not ours. "via-double loses to glibc at narrow gaps" (line ~121) measured libc fmod + widening. Shipped fmodf numbers unaffected.
- Gate weakness: brokenf.c corrupts all 3 fmodf paths at once; libc-test fmodf control corrupts only d<=8. Wanted: one corrupted twin per path (d<=8, d<=40, general).
- Pre-existing, parked: Dockerfile.prebuilt-base never COPYs the fmod .s (cp aborts; moot since PGO_STAGE=use forces cold); patchset-hash.sh doesn't hash libm-fmod-custom/*.c.
- Missing vs glibc/Rust fmodf: shift y's trailing zeros into the gap; multiply-by-1/y big-gap reduction. Real chromium calls (~1,600/run) are all x<y or gap 0-8, so barely matters; only Haswell big gaps would gain.
- Firefox build proving the libxul fmodf link: run 37988293902 on perf/fmodf-microbench (dispatched on jean's go). Post-merge main runs 37985301500/111/088 all green, ff-latest promoted with fmod linked.
- tests-aports token fix landed 807d503 (Bearer GITHUB_TOKEN only for https://api.github.com/); proof = the run main's push triggers.

## fmodf tweak round (2026-10-10, scratchpad only, NOT pushed to #334)
- Kept: both-subnormal `ax % ay` (0.55x gcc/0.72x clang), x86 `divl` 64/32 for d 9..40 (0.54-0.78x), 64-bit reciprocal only when gap >155 (c250 0.51x). Gaps 0-8 unchanged (the only gaps chromium hits). Haswell only; CI CPUs unmeasured.
- Dropped: ctz-shift of y (4-24% slower gaps 9-29), glibc 32-bit reciprocal (1.6-2.2x slower gap>=48), reciprocal from gap 41 (loses g48/g64), Rust special-case check (gate RED: fmodf(0x7f800001,0x7fc00000) gives 7fc00001 vs musl 7fc00000), double-precision quotient (divsd raises spurious FE_INEXACT).
- vs glibc 2.39: ours 2-3x faster for random y gap>=9; glibc ~7% faster gaps 1-8, both-subnormal, short-significand y.
- Shipping needs gate rewrite: old fmodf corruption seds no longer match; corrupt per path with `+ 1`: `r_mid = narrow_rem(mx24 << d_fast, my24 + 1)`, `mx32 = narrow_rem((uint64_t)mx32 << 31, my32 + 1)`, `mx64 = wide_mx - q_est * my32 + 1` (covers review findings 5,6).
- Gotcha: cosmetic type change (mx/my to uint32) cost 4% at gaps 1-8 with identical insn count (regalloc/layout). After any cosmetic edit, objdump-compare to the benched build.
- divl faults (#DE) if quotient >32 bits; every call site hand-checked. Portable `/`,`%` fallback off x86.
- Proposal awaiting jean: one commit on #334 (new fmodf + gate rewrite + findings 4,7,8,9 + comment for 1); CI per-gap microbench dispatch. Files: scratchpad d4d4014d.../fmodf-tweaks/{libm-fmodf-custom.c,tw/run-gate-final.sh}.

## fmodf idle bench 2026-10-10, two Intel generations (cycles/call, median)
- Haswell i3-4005U (3 reps, cycles stable to 0.1): final vs shipped gaps 0-8 25 vs 25 (1.00), gaps 9-29 27 vs 45 (0.60), g250 166 vs 273 (0.61), sub0 22 vs 40 (0.55). vs glibc 2.39: gaps 1-8 26 vs 24 (1.08), sub0 1.10, c64-c250 1.15-1.25; gap 9+ 0.31-0.50.
- Kaby Lake R i5-8350U (load ~2, 3 reps): gcc-musl final gaps 1-8 26 vs 23 (1.10) SLOWER, same insn count (54 vs 55). Cause: code layout. Shipped .so padded the d<=8 block to 0x1200; final's starts at 0x11d8 → Skylake-family JCC-erratum (jcc crossing a 32B line drops out of the DSB). Haswell has no erratum, hence flat there.
- Fix measured: gcc `-Wa,-mbranches-within-32B-boundaries`. Kaby 5 reps final+flag vs shipped: gaps 0-8 0.88-0.97, gaps 9-12 0.56. Haswell 3 reps: costs +1 cycle at gaps 0-8 (26 vs 25, 1.04); elsewhere within 1 cycle.
- 0 mismatches on every rep, both boxes, musl gcc/clang-23 and glibc.
**How to apply:** any gcc build of libm-fmodf-custom.c (preload + Firefox .s) needs the flag if the final code ships; a hot path's speed on Skylake-family is layout luck without it. Recheck with an objdump of the d<=8 block address.
