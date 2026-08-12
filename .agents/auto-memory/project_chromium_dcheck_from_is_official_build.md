---
name: project_chromium_dcheck_from_is_official_build
description: Our musl chrome-headless-shell shipped with DCHECKs ON because is_official_build=false flips Chromium's dcheck_always_on default — layout 9.3x / DOM 7.2x slower than official; aports builds musl chromium with is_official_build=true instead
metadata:
  type: project
---

`args.gn.overlay` set `is_official_build = false`. Chromium's own default is

    dcheck_always_on = (build_with_chromium && !is_official_build) || dcheck_is_configurable

(`build/config/dcheck_always_on.gni`), so a **release** build silently compiled
DCHECKs in. Nothing in `apply-and-build.sh` asks for them — it only sets them
under `PW_CHROMIUM_ENABLE_DEBUG=1`.

**Measured vs the official glibc chrome-headless-shell** (same probe, 3/3
reproducible): layout **9.3×**, DOM churn **7.2×**, JS heap **2.9×**, integer JIT
loop **1.9×**. Blink's layout/DOM is DCHECK-dense, which is why the penalty
concentrates there. This is the whole reason alpine "tests" columns ran ~50%
slower than ubuntu in the benchmark.

**Artifact-level proof:** `strings` on the shipped binary → **77** `^DCHECK failed`
hits vs **0** in the official one (its 5 hits are flag help-text); 305 MB vs
185 MB. See [[reference_verify_build_flags_via_binary]].

**aports is the reference config** (`community/chromium` APKBUILD): it builds musl
chromium with `is_official_build=true` and disables the costly/unsupported
sub-features individually — `chrome_pgo_phase=0`, `use_thin_lto=false`,
`is_cfi=false`, `is_debug=false`, `symbol_level=0`. So "official" is proven on
musl and buys the optimization level + DCHECK-off default WITHOUT PGO/LTO cost.
PGO is separately infeasible: profiles are fetched by depot_tools and are tied to
Google's bundled clang, not Alpine's system clang.

**In flight (2026-08-12):** two concurrent from-source builds A/B this —
`3e713ce` on main (`dcheck_always_on = false` only) vs `765edbf` on
`perf/chromium-official-build` (`is_official_build = true` + the three aports
offs). Expect the chs layer (138 MiB compressed, the one the strip work can't
touch) to fall with the binary. Also re-check whether
[[project_chromium_headed_dcheck_sys_nice]]'s `--cap-add SYS_NICE` workaround is
still needed — that DPCHECK is only fatal in a DCHECK build.
