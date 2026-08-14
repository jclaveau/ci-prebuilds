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
~~PGO is separately infeasible: profiles are fetched by depot_tools.~~ **Wrong** —
the profile is a public download and `pgo_data_path` skips depot_tools entirely;
see [[project_chromium_gn_perf_knobs]].

## Settled 2026-08-14

**DCHECKs off is a clear win, and it shipped in `3e713ce` itself.**
Test time vs the in-run glibc control: **1.27× → 1.10×**, two before-runs and two
after-runs ([[project_conformance_control_leg_test_time]]).

**The A/B that ran was NOT DCHECK-on vs off** — both arms carried
`dcheck_always_on = false`, since `3e713ce` *is* the control arm's HEAD. Binaries
agree: `DCHECK` markers 5 vs 5, `Check failed` 49 vs 48. It measured
`is_official_build` alone, which bought:

```
screenshot 0.75x | layout 0.93x | everything else inside sample spread
101.8 -> 85.8 MiB compressed (-15.7%)   |   build +1h08   |   test time unchanged
```

Adopted anyway (`f28b6b6`) on jean's call: the goal is consumers' CI, not ours —
time-to-tests is ~entirely image pull, so we pay the hour so they don't. The
overlay comment records that flipping it back to `false` while iterating on the
build is worth ~an hour per round-trip.

The 9.3× / 7.2× figures above are **our DCHECK build vs PW's official glibc
build** — a different comparison than `is_official_build` alone, and not a claim
about that flag ([[feedback_verify_ab_varied_the_variable]]).

Still open: `--cap-add SYS_NICE` ([[project_chromium_headed_dcheck_sys_nice]])
may now be unnecessary — that DPCHECK is only fatal in a DCHECK build.
