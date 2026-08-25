---
name: project_ff_build_missing_pgo_lto_jemalloc
description: our musl Firefox is built with no PGO, no LTO and no mozjemalloc because we invoke ./mach build directly and skip the aports APKBUILD build() that adds all three — the leading explanation for its screenshot/launch/layout gap
metadata:
  type: project
---

`firefox/mozconfig.overlay` sits on aports' `mozconfig` and adds ONLY
`--with-ccache=sccache`. Everything else lives in the APKBUILD's `build()`,
which we never run because we call `./mach build` ourselves. So we lose:

| lever | where aports puts it | ours |
|---|---|---|
| PGO | `optimised-mozconfig` (`--enable-profile-{generate,use}=cross`) | absent |
| LTO | `optimised-mozconfig` (`--enable-lto=cross`) — **not** in base | absent |
| mozjemalloc | base has `--disable-jemalloc`, so musl malloc | absent |

`grep -c lto` on the base mozconfig returns **0** — LTO is not a base option,
it is added beside PGO. An earlier note here claiming "LTO-but-not-PGO" was
wrong; skipping `build()` drops both together.

**Why it is the leading candidate.** perf-firefox (run 32782133911, three arms,
one runner) puts our build's only real deltas at `screenshot` 1.20, `launch`
1.16, `layout` 1.09 — all C++ — while every JIT-executed kernel (`eval_rtt`,
`int_math`, `js_alloc`) is at parity, which is the shape a missing C++
optimisation makes. The same lever on chromium in this repo went geomean
1.42 → 1.28 (PGO), → 1.12 (PGO+ThinLTO, super-additive)
([[project_chromium_perf_arms_1_62]]).

**Cost ladder, cheapest first:**
1. **allocator** — `LD_PRELOAD` a different malloc at RUNTIME, no rebuild.
2. **LTO only** — one build (~5-6h), no profiling infrastructure.
3. **PGO+LTO** — instrumented build + `build/pgo/profileserver.py` under
   xvfb + dbus + `./mach clobber` + optimised build, so ~2x a full build.

**How to apply:** do not quote our FF as "optimised like the distro build" —
it is the distro's SOURCE with none of the distro's optimisation. Measure with
perf-firefox's three arms, not a two-arm ours-vs-official
([[project_alpine_browser_perf_vs_glibc]]).
