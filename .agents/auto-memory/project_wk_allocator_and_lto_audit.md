---
name: project_wk_allocator_and_lto_audit
description: WebKit's USE_SYSTEM_MALLOC and JIT-tier hypotheses are both refuted on the shipped artifact; the live leads are ThinLTO (off, while Alpine's own build turns it on) and extending the mimalloc shim past bmalloc
metadata:
  type: project
---

Audited 2026-08-27 against the published `wk-2336` (layer blob pulled from GHCR,
`libWPEWebKit-2.0.so.1.10.2` inspected directly), with PW's own
`webkit-ubuntu-24.04.zip` at the same revision as the control.

**`USE_SYSTEM_MALLOC` — REFUTED, do not run the firefox playbook here.** Nobody
sets it (`cmake-flags.overlay` has no malloc line, and unlike firefox there is no
aports graft for webkit so no distro patch can force it). Upstream at our pinned
base `4d05d732`, `Source/cmake/WebKitFeatures.cmake` sets
`USE_SYSTEM_MALLOC_DEFAULT OFF` for `WTF_CPU_X86_64` **with no libc condition** —
the musl-forces-system-malloc folklore is not in this tree. The artifact agrees:
ours carries `pas_` x80, `bmalloc` x16, `libpas` x7, `IsoHeap` x11 including
compiled-in `/work/webkit-src/Source/bmalloc/libpas/…` paths; official has the
same shape. Both run bmalloc/libpas.

**The `nm -D` discriminator that cracked firefox does NOT transfer to webkit**:
`malloc` is undefined in BOTH libs, because bmalloc backs `WTF::fastMalloc` and
never interposes global `malloc`. Use the `pas_`/`bmalloc` string counts instead.

**JIT tiers — REFUTED.** Ours: DFG x1513, FTL x360, `B3::` x728, `Air::` x216,
Wasm x557, LLInt x71, **CLoop x0**; official the same shape. Full tier stack, no
interpreter fallback. `ENABLE_JIT=ON` is explicit in `cmake-flags.overlay`.

**Live lead 1 — ThinLTO is OFF and Alpine's own webkit turns it ON.**
`cmake-flags.overlay` has `-DLTO_MODE=thin` commented out over link-step RSS
fears; upstream has no default, so we ship non-LTO. Alpine's
`community/webkit2gtk-6.0/APKBUILD` sets `-DLTO_MODE=thin` for x86_64 alongside
clang + lld + llvm-ar, which we already match. This repo's own chromium arms put
ThinLTO alone at geomean 1.42 -> 1.31. **Unknown whether official PW webkit uses
LTO** — PW's webkit build scripts are not public at v1.62.1, and `.text` size is
NOT a discriminator (ThinLTO grew chromium's above official's). Cost: one ~4h
WPE-only dispatch.

**Live lead 2 — the mimalloc shim stops short of webkit's real allocator load.**
`Dockerfile.alpine` scopes the shim to firefox, reasoning that "chromium's
PartitionAlloc and webkit's bmalloc are left alone". But bmalloc only backs
`fastMalloc` (WebCore + JSC); GLib/GObject, GStreamer, Skia, Cairo, HarfBuzz, ICU,
libsoup, fontconfig and freetype all go to musl mallocng — the same thing that
cost firefox screenshot/launch/eval_rtt. `mimalloc2-insecure` already ships in the
image and `pw_run.sh` is a one-line hook, so this is minutes, not hours. Run
webkit conformance on the arm before shipping
([[feedback_unskip_regression_beyond_target]]).

**Neutral — do not spend a round:** `-O3` is what we already compile at
(`CMAKE_CXX_FLAGS_RELEASE` is `-O3 -DNDEBUG` and wins as the later flag);
`-U_FORTIFY_SOURCE` is what Alpine's own APKBUILD does and is a gain if anything
([[project_webkit_fortify_source_skia_trap]]); frame pointers are omitted on both
(`DEVELOPER_MODE OR ARM`); neither side sets `-march`; the strip and flat
`$ORIGIN` layout keep `.dynsym`/`.gnu.hash`/relocs (`SHF_ALLOC`), so no load-time
asymmetry. `SIMDUTF_IMPLEMENTATION_ICELAKE=0` is ours only (an AVX-512 SIGILL
guard) — read it as a *note when interpreting* `goto_cold`/`dom_churn` on an
AVX-512 runner, not as a knob to flip back.

**How to apply:** every ratio here is a prediction — no post-move WebKit had ever
been benched, because `perf-probe` skipped our images. Land the measurement first,
then pick lead 2 (minutes) or lead 1 (hours) from *which metrics are red*.
[[project_wk_pw162_requires_265]], [[project_alpine_browser_perf_vs_glibc]]
