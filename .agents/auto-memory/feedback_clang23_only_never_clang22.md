---
name: feedback_clang23_only_never_clang22
description: clang22 is dead in this repo — every build, bench and codegen probe uses clang23 (the browsers' compiler); a bare `apk add clang` on 3.24 gives clang22 and is a mistake
metadata:
  type: feedback
---

We don't and won't use clang22 anymore. All three browsers build with clang23, so every
compiler-dependent measurement (microbench builds, asm diffs, llvm-mca, PGO tools) uses clang23.

**Why:** jean 2026-10-09, after the fmod per-gap microbench timed `unified.c` with alpine:3.24's
bare `clang` (22.1.3) while libxul builds with alpine:edge clang23. clang23's wide_reduce has
no imul/bt trip-count prologue, so the whole clang-vs-gcc / clang-vs-Rust verdict was measured on
the wrong compiler. The Rust row had the same flaw (3.24 `rust`, not edge's cargo).
**How to apply:** never `apk add clang` on a 3.24 image; install `clang23` (binary
`/usr/bin/clang-23`, tools under `/usr/lib/llvm23/bin`) or run in alpine:edge. Match every
toolchain in a probe to the builder that ships the browser (Rust too). Don't propose clang22 as a
candidate or fallback. See [[project_chromium_clang23_lever]], [[project_wk_clang23_epoch_ab]],
[[project_fmod_everywhere_preload_vs_patched_musl]].
