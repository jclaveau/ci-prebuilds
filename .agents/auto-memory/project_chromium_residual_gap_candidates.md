---
name: project_chromium_residual_gap_candidates
description: our chromium sits ~1.3x official even with PGO or ThinLTO — ranked candidates for the residual, and the three cheap probes that partition them
metadata:
  type: project
---

After either perf knob, alpine chromium is still ~1.28-1.31x official on geomean
and **1.89x on layout** ([[project_chromium_perf_arms_1_62]]). The arms argue over
~3%; the unexplained residual is ten times that. Ranked candidates:

1. **musl malloc instead of PartitionAlloc.** The from-source setup log shows
   aports patching `partition_alloc.gni` and
   `allocator_shim_default_dispatch_to_partition_alloc.cc` for musl, i.e. the
   allocate-everything-through-PartitionAlloc path is not what official uses.
   musl's mallocng is markedly slower under churn. Fits `dom_churn` 1.67 and
   `js_alloc` 1.16 directly. **NOT excluded by `libm_fmod` = 1.00** — that clears
   musl's libm only ([[feedback_control_excludes_one_mechanism]]).
2. **Unbundled system libs on the text path.** `USE_SYSTEM_LIBS` in
   `apply-and-build.sh` hands Chromium Alpine's **fontconfig, freetype, harfbuzz,
   highway** instead of Chromium's pinned forks. Top suspect for layout: the
   probe's layout kernel forces 2000 synchronous relayouts over ~900 text-bearing
   nodes (800 `lorem ipsum` rows + 100 buttons), so shaping and font metrics
   dominate it.
3. **Alpine clang 22 instead of Chromium's pinned clang** (`custom_toolchain =
   //build/toolchain/linux/unbundle:default`, `clang_use_chrome_plugins = false`).
   Not excluded by `int_math` = 1.00: that kernel runs V8 JIT output, machine code
   emitted at runtime that no C++ compiler difference can touch.
4. **Different font sets per runner** — alpine `font-opensans`/`ttf-freefont` vs
   noble's DejaVu/Liberation. `system-ui` resolves differently, so shaping cost
   differs. A runner-config difference, not a build one.
5. **The reference is not a like-for-like binary** — PW's image reports *Google
   Chrome for Testing 151.0.7922.34*, an official Google build with PGO+LTO+CFI,
   its own toolchain and everything bundled. Part of the residual may be
   structural.

**How to apply:** three cheap probes partition this without a ~40h rebuild —
(a) a text-free layout kernel (collapse ⇒ candidate 2), (b) noble's font set
installed into the alpine probe image (separates 4 from 2), (c) `nm`/`strings` on
the shipped `chrome-headless-shell` for the PartitionAlloc shim (settles 1,
[[feedback_strings_splits_compile_from_runtime]]). Related:
[[project_alpine_browser_perf_vs_glibc]], [[project_runtime_perf_probe]],
[[project_chromium_dcheck_from_is_official_build]].
