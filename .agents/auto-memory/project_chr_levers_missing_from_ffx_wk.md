---
name: project_chr_levers_missing_from_ffx_wk
description: Audit of chromium-only build levers not yet applied to firefox/webkit — PGO missing from WK (biggest gap), FF/WK eat aports' hardening driver chr's Dockerfile.clang skips, plus march-v3/ICF/symbol_level=0 tail; ranked dispatch order
metadata:
  type: project
---

2026-09-24 audit of all three overlays + toolchain Dockerfiles for chromium-only levers not ported to firefox/webkit.

| # | Lever | chr | ffx | wk | portable? |
|---|---|---|---|---|---|
| 1 | PGO | yes (`chrome_pgo_phase=2`) | yes (2-job generate/use, [[project_ff_pgo_arm_mechanics]]) | **no** | yes — FF's PGO_STAGE=generate\|use pattern is the template |
| 2 | Vanilla clang, no aports driver patches | yes (`Dockerfile.clang` snapshot) | no (alpine `clang23`) | no (alpine `clang`) | partly, via CFLAGS |
| 3 | `-march=x86-64-v3` | arm in flight (run 35969194229) | no | no | trivial, one line each — needs opt-in tag, SIGILL risk on pre-AVX2 |
| 4 | `symbol_level=0` (no debuginfo) | yes | no (FF default `-g` on) | n/a (Release, no `-g`) | FF only |
| 5 | ICF (`--icf=all`) | yes, free via `is_official_build` | no | no | one linker flag each |

Reverse direction: mimalloc preload ships for FF+WK, not chromium (PartitionAlloc) — not a gap.

**#1 WebKit has no PGO — biggest single gap.** chr went 1.42→1.12 geo with PGO+ThinLTO; FF's PGO arm alone read 0.74. WebKit cmake has no PGO flow — would be hand-rolled: `-fprofile-generate` into `CMAKE_{C,CXX}_FLAGS`, a profile run driving MiniBrowser over the probe corpus, `llvm-profdata merge`, then cold `-fprofile-use` rebuild. Two full builds ≈ 2×4h + gate. Note [[project_ff_pgo_corpus_append_experiment]]'s "training on the graded workload is not a lever" answered a *different* question (WK currently has no profile at all, so the base PGO win is still open).

**#2 Toolchain posture — FF/WK eat aports' hardening driver, chr doesn't.** `Dockerfile.clang` builds a snapshot clang "deliberately NOT reproducing alpine's hardening driver patches" and forces SSP level 1. FF and WK build with packaged `clang23`, so both pay forced `-fstack-protector-strong`/`-fstack-clash-protection`/fortify include path, and lose the 3 codegen flags aports' `compiler.patch` strips ([[project_chromium_libc_ladder]]). WK already neutralizes fortify (`-U_FORTIFY_SOURCE`, see [[project_webkit_fortify_source_skia_trap]]); **FF neutralizes nothing** — and the chromium nav win (PR #273, [[project_chromium_nav_gap_is_musl_fortify_overlap_check]]) was exactly musl fortify's inline memcpy overlap check in Skia raster, and FF ships its own Skia. Cheapest experiment in the whole list: two flags into FF's `CFLAGS` default at `apply-and-build.sh:546`.

Recommended order: FF fortify-off (hours, existing gate) → WK PGO plumbing (~a day) → ICF on both → march-v3 once the chromium candidate rules.
