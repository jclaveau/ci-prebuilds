---
name: project_wk_launch_is_the_loader
description: RESOLVED 2026-09-08 — root cause was Mesa's libgallium->libLLVM (235 MB) pulled into every process because Alpine has no libglvnd; fixed USE_GSTREAMER_GL=OFF (PR #180), launch 1.47->0.88 n=10; DT_RELR and lazy binding both exonerated first
metadata:
  type: project
---

`launch` is the one metric the mimalloc preload did not move (1.29-1.37 ->
1.31-1.35 across three same-CPU pairings). What it is NOT, measured:

**Not the DSO closure** — the thing that explains chromium's launch gap
([[project_chromium_launch_dso_closure]]). Ours is the LEANER side:

```
                       ours    official
libWPEWebKit DT_NEEDED   60          70
MiniBrowser  DT_NEEDED   16          74
```

**Not relocation count, and not library size.** Ours is smaller on both axes
and still loads slower:

```
                       ours          official
.text                  91.9 MB       98.6 MB
relocation entries     320,694       339,342
RELACOUNT (RELATIVE)   313,989       332,177
dynamic symbols          4,036         3,955
```

**Not BIND_NOW**, though ours links it and official does not (ours carries
`FLAGS BIND_NOW` + `FLAGS_1 NOW`; official's dynamic section has neither). A
within-binary A/B on OFFICIAL — `RTLD_NOW` vs `RTLD_LAZY` via dlopen, which
holds every build difference fixed — showed no cost for eager binding; its
`NOW` runs were if anything faster than its `LAZY` ones, i.e. noise dominates
the effect. Only ~3,150 PLT entries separate the two modes, so this was always
a small candidate. Note `RTLD_LAZY` is INERT on our lib: `DF_1_NOW` in the
object overrides the dlopen flag, so ours cannot be A/B'd this way at all.

**What is left.** A raw `dlopen` of the two libraries, best-of-8 on one box:
ours ~84 ms, official ~56 ms — a ~28 ms gap that is the right size for the
launch delta (98.6 vs 74.1 ms on the probe). Since ours has fewer relocations
and less text, the per-relocation cost differs, which points at musl's dynamic
loader rather than at anything in our build. Treat as a LEAD, not a finding:
the box was loaded and official's spread was 55.8-133 ms.

To settle it properly, run the dlopen bench on a quiet runner, and note the
`ubuntu` probe arm CANNOT decide this — it is a glibc container running PW's
own binary, so it holds neither the loader nor the build fixed.

**Negative result (2026-09-08, PR #143's DT_RELR arm).** Packing the
313,989/320,694 RELATIVE relocations into `DT_RELR` (musl 1.2.6 supports it)
shipped, built, and was verified present on the probed artifact end-to-end —
and moved nothing: `launch` 1.42 vs 1.44 control, n=10 same machine, within
noise. So the RELOCATION FORMAT is not the lever despite ours already having
fewer relocations and less `.text` than official; whatever the loader is
paying per relocation, packing them differently doesn't touch it. Next
instrument queued for this and the other unexplained rows is a differential
`perf record` on the WebProcess (ours vs official, one runner, symfs diff),
not another static candidate.

Also ours-only: `USE_LIBBACKTRACE=OFF` (official ships `libbacktrace.so.0` in
`minibrowser-wpe/sys/lib/`), and our layout is flat with `RPATH=$ORIGIN` while
official splits `bin/`, `lib/` and `sys/lib/`
([[project_wk_artifact_flat_lib_layout]]).

**Lazy binding: also dead, verified arm.** Clearing `DF_BIND_NOW`/`DF_1_NOW`
on every bundled ELF (needs no rebuild — PLT stubs are emitted regardless)
gave `launch` 1.45 vs shipped 1.44, every other row flat, n=10 same runner.
`gnu_lookup_filtered` is genuinely the hot loader function seen in the
profile below, but deferring lookups doesn't help — the cost is per lookup
actually needed, not per symbol-table walk.

**The differential profile that found it.** `perf record -a` (system-wide,
not `--pid` — WebKit recycles the WebProcess and the pid can vanish before
attach) with `sudo` (unprivileged perf can't read `/proc/<pid>/maps` for a
root-owned container, so only the non-root arm resolved without it) on a
`launch`-only kernel (repeatedly `browserType.launch()` + `close()`, isolated
from everything else since a loader is a short-lived process). Top DSO both
arms: the loader — ours `ld-musl` 10.34%, official `ld-linux` 8.82% (in musl
`ld-musl-x86_64.so.1` **is** libc, so the fair comparison is 10.34% vs
official's 8.82%+`libc.so.6`'s 0.80% = 9.62%, not the naive 13x). Also
carried ours-only: `libgcc_s` at 2.28% of *all* samples vs official's <0.17%,
offsets past `_Unwind_Backtrace` = GCC's static DWARF unwinder — measured,
never chased further (superseded by the root cause below).

## Root cause and fix (2026-09-08, PR #180)

Not the loader being slow — **what it loads.** Alpine has no libglvnd, so
`mesa-egl`'s `libEGL.so.1` is not a dispatch stub (Ubuntu's is) — it directly
`DT_NEEDED`s libgallium (44 MB) which pulls in libLLVM (191 MB), all mapped
and relocated before `main` runs, in all three processes a launch starts. The
only edge reaching `libEGL` in our build is `libWPEWebKit` -> `libgstgl`.
Stub-priced before touching the build: closure 124->107 objects, `ld.so
--list` 70->36 ms, `MiniBrowser --version` 121->64 ms (under Playwright's own
41 ms equivalent).

**Fix:** `-DUSE_GSTREAMER_GL=OFF` in
`playwright/alpine-browsers/webkit/cmake-flags.overlay`, plus a two-hunk
source patch (`patch_dmabuf_without_gstreamer_gl` in
`scripts/prep-source.sh`) since upstream WebKit doesn't compile in that
configuration otherwise — `VideoFrameGStreamer.h`'s `MemoryType::DMABuf` enum
member and `VideoFrameGStreamer.cpp`'s `gst_dmabuf_memory_get_fd` both sit
behind the `USE(GSTREAMER_GL)` guard and needed moving to `USE(GBM)`.

Validated on a producer branch dispatch (run 34189647309: 4 WPE rounds,
smoke, and **every** `conformance-webkit` shard green) before merge. n=10,
control in the same job: **`launch` 1.31/1.47 -> 0.87/0.88**, `screenshot`
and `layout` unaffected. Combined with the zlib-ng screenshot fix
([[project_wk_screenshot_is_alpine_os_libpng]]) in one image
(`sha-ea0b8149…`), both hold together with no interaction.

**Gotcha — a producer-side fix does not ship by merging to main.**
`promote-webkit` only moves the `wk-2336`/`wk-latest` tags from a **main**
run with `build_webkit=true`; #180 was validated on a branch, so by design it
published only the sha-scoped tag (`wk-sha-0b4bd1d4…`), never touching the
moving tags. Merging #180 to main then ran a **push** build, where WebKit is
dispatch-gated off — nothing rebuilt, nothing promoted. So `latest`'s
`org.opencontainers.image.revision` still pointed at the pre-#180 WebKit
(`fac3bb3`, #141/ThinLTO) hours after the merge looked done. Always diff the
shipped tag's revision label against the fixing commit before calling a
browser-side fix live — see [[project_wk_promote_gate_holds_the_nightly_bench]]
for the retag-vs-rebuild decision this forced.

**Gotcha — an override-dispatched "proof image" doesn't validate the default
path.** `sha-ea0b8149…` (n=10 numbers above) only exists because TP was
dispatched with an explicit `wk_source_tag` override; at that commit
`Dockerfile.alpine`'s default was still `ARG WK_SOURCE_TAG=wk-${WK_REV}` →
the old producer. It proved the WebKit artifact was good, never that merging
would ship it — and it didn't (see the gotcha above). Don't call an
override-built image "the shipped state"; confirm the DEFAULT-path build
resolves to the fix too.

**SHIPPED 2026-09-08.** Retag executed
([[project_wk_promote_gate_holds_the_nightly_bench]]) + consumer rebuilt via
PR #192 on the default (unpinned) `wk-2336` tag. `latest` at revision
`d674548` reads `launch 0.87` on its own inline probe (EPYC 7763) — the gap
is closed in what users actually pull, not just on the proof artifact.
