---
name: project_wk_clang23_epoch_ab
description: WebKit has no LLVM version pin (unlike firefox's aports _llvmver) so it silently auto-follows alpine:edge's default clang — last built Sept 8, pre-dating edge's ~Sept 22 LLVM-23 flip, so wk-2336 ships clang22-era; A/B DISPATCHED 2026-09-24 (run 35972784207), source-prep CONFIRMED it landed on clang 23.1.2 as predicted — perf-gate-webkit result still pending
metadata:
  type: project
---

Unlike firefox, which pins `_llvmver=22` in aports against edge's moving
runtimes ([[project_ff_alpine_edge_llvm23_skew]]), `webkit/Dockerfile.source-prep`
installs **unversioned** `clang clang-dev lld llvm-dev compiler-rt` on
`alpine:edge`. No versioned LLVM reference anywhere in
`playwright/alpine-browsers/webkit/` or the wk workflows — WK just gets
whatever edge's default clang is that day. That is exactly why the LLVM-23
flip never broke WK the way it broke firefox: WK has nothing to diverge
from, it just floats.

But floating means the shipped binary is dated by when it was last built,
not by what edge carries today. Consumer `wk-2336` / `wk-latest` was last
built **2026-09-08** (sha `0b4bd1d`), which predates edge's LLVM-23 flip
(~2026-09-22) — so it shipped compiled with clang **22**, one edge cycle
stale, and gets clang 23 free on the next rebuild with no patch needed
(chromium's clang23 lever, [[project_chromium_clang23_lever]], took a
dedicated toolchain-pin bump; WK's upgrade is a no-op dispatch).

**A rebuild alone would not measure it.** `cache-from:
…buildcache-wk-src` restores the Sept-8 `apk add` layer verbatim whenever
the Dockerfile text is unchanged, so a plain rebuild reuses the cached
clang-22 layer and the A/B is vacuous. Fixed with a deliberate cache-bust:
added a `WK_TOOLCHAIN_EPOCH` build ARG (referenced by that `apk add` layer,
empty default = no-op) plus a matching `webkit_toolchain_epoch` workflow
dispatch input, and made the layer print `clang --version` so the build log
records which toolchain actually landed (PR #302).

**How to apply:** to run the A/B, merge #302, then dispatch with
`build_webkit=true`, `webkit_toolchain_epoch=2026-09-23` (or any new value —
it only needs to change to bust the cache), GTK off (WPE-only halves the
build), then perf-gate `wk-sha-<new>` vs `wk-latest`. Unmeasured as of
2026-09-23 — chain queued behind the chromium campaign.

**DISPATCHED 2026-09-24.** #302 merged (1461aad, same commit carries the
`clang --version` echo, so `git log -S` on that string finds it directly).
Confirmed on Alpine edge *today* bare `clang` resolves clang23
(`p:clang=23.1.2-r0`, `p:llvm-dev=23-r0`; 20/21/22 coexist as separate
packages) — consistent with this file's ~2026-09-22 flip date, not new
information, but no longer an inference. Dispatched
[run 35972784207](https://github.com/jclaveau/ci-prebuilds/actions/runs/35972784207)
on `main`, `build_webkit=true webkit_toolchain_epoch=2026-09-24`,
`run_webkit_conformance=true` (required — `promote-webkit` needs
`[build-webkit-finalize, smoke-webkit, conformance-webkit,
perf-gate-webkit]` all green, so a faster build without conformance
couldn't promote and the epoch bump would cost a second full build to ship
regardless), GTK off. Separate `pab-refs/heads/main-wk` concurrency group
and GHCR `buildcache-wk-src` cache, so it does not contend with the four
parallel chromium chains
([[project_chromium_residual_gap_candidates]]'s 2026-09-24 dispatch).
Uncached `apk add` plus a fresh WebKit clone was estimated to land the
`clang --version` line inside ~20 min (vs the 8m54 cached-layer baseline
on run 34189647309) — result not yet read as of this memory.

**Result, 2026-09-24: confirmed.** `build-webkit-source-prep` on run
35972784207 went green and the `clang --version` echo read `Alpine clang
version 23.1.2` (llvm23 23.1.2-r0) — the new toolchain epoch is clang 23,
as this file predicted from edge's package state, now measured on the
actual build rather than inferred. `build_webkit` / conformance /
`perf-gate-webkit` were still running as of this note (~55 min into the
4h08–4h39 cached-toolchain band) — the perf delta from the clang bump
itself is not yet in.
