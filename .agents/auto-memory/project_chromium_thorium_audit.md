---
name: project_chromium_thorium_audit
description: audited Thorium (Alex313031/thorium) as a drop-in chromium replacement for PW tests — NOT VIABLE (138 LTS vs PW's pinned 151, no chrome-headless-shell target, ships heavier not lighter); its codegen tweaks are the reusable part, ranked into a 3-step ladder (libc++ hardening FAST #1, AVX2+FMA baseline #2, mllvm lore flags #3-park); BOLT/Polly both dead on Alpine (no packages, no self-built LLVM); Thorium's "parallel downloads" is a browser file-download feature, irrelevant to CI
metadata:
  type: project
---

**Ask (2026-09-17):** investigate whether Thorium (a Chromium fork with
perf/branding patches) could replace our chromium build for PW tests, to
save CI download time and test-run time.

**Drop-in verdict: no.**
- Thorium tracks Chromium **138.0.7204.306** LTS; PW 1.62 pins
  **151.0.7922.x** — CDP surface drift would read as conformance red, not
  noise.
- Ships `chrome` + `thorium_shell` (= content_shell); no
  `chrome-headless-shell` target at all. Would have to run as full
  `chrome --headless`, a different artifact than what PW expects.
- Heavier, not lighter for our use: full browser + Widevine + HEVC/AC3 +
  ffmpeg + branding. 95% of the overlay (chrome/app 134 files, widevine 38,
  webui 39) is UI/codec/privacy patching with zero effect on a headless
  target; our fs artifact is 217 MB, Thorium's deb is roughly 2×.

**Codegen tweaks, checked one by one against our `args.gn.overlay` /
upstream 151 defaults** (full table lives in the session transcript, not
reproduced here — this is the actionable subset):

- **No-ops** (Thorium's setting already matches our/upstream official
  default): ThinLTO optimisation level, `init_stack_vars_zero`,
  `exclude_unwind_tables`, `use_icf`, `enable_stripping`, V8 codegen args,
  `optimize_webui`, `partalloc.patch`'s VMA-count knob (already Finch-on).
- **#1 candidate — libc++ hardening EXTENSIVE → FAST** (or
  `enable_safe_libcxx=false` = NONE, stronger but a real security
  downgrade). Removes `_LIBCPP_HARDENING_MODE_EXTENSIVE`'s runtime checks
  on `vector`/`span` etc. in hot Blink C++. The only lever in this audit
  that can plausibly push *below* official, since official pays EXTENSIVE
  too (`build_overrides/build.gni`). One-line `BUILD.gn`/gn-arg change.
  Same lever [[project_chromium_hardening_removal_candidates]] (issue
  #259) ranks #3 from the opposite motivation (hardening a test container
  doesn't need) — converge on one A/B, don't run it twice.
- **#2 candidate — SIMD baseline SSE3 → AVX2+FMA** (Thorium also offers
  plain AVX). GH-hosted runners are all AVX2-capable (Ice Lake/Zen3); helps
  generic Blink codegen (VEX encoding, fewer movs). Skia/V8 already
  runtime-dispatch SIMD so no gain there specifically. Would need an
  opt-in tag (SIGILL on older/self-hosted CPUs), never the default arm.
- **Passenger, cheap: `-fsized-deallocation`** (Thorium sets it in
  release; upstream is `-fno-`). Small, touches PartitionAlloc's sized-free
  path, worth bundling with #1 rather than its own chain.
- **Skip — `-ffp-contract=fast`** (Thorium pairs it with FMA/AVX2):
  changes float rounding, so `layout_text` checksums and screenshot
  bytes would diverge → conformance flake risk for a codegen-only intent.
- **Contrary to our own diagnosis — `-O3` everywhere,
  `import_instr_limit` 30→100**: our residual gap is front-end
  instruction-fetch bound (iTLB 2.3×, 1.6× more hot text pages,
  [[project_chromium_layout_gap_is_frontend_fetch]]); both of these GROW
  code. Low priority, possibly counter-productive.
- **#3, low priority, park — `-mllvm -enable-gvn-hoist`,
  `-aggressive-ext-opt`, `-enable-pre=false`**: RobRich999-lineage lore
  flags with a history of miscompiles upstream; gvn-hoist mildly shrinks
  code (fetch-friendly in principle). One bundled candidate at most, after
  #1 and #2 are read.
- **Parked — BOLT / Polly**: both are commented OUT in Thorium's own
  `args.gn` (not actually shipped). BOLT specifically matches our
  iTLB/two-.text-band diagnosis conceptually, but Alpine ships neither
  package (`apk search bolt` = Thunderbolt manager, not `llvm-bolt`) and
  running it needs a self-built LLVM (the `chs-clang` snapshot image plus
  the BOLT subproject) — same class of toolchain investment as
  [[project_chromium_snapshot_lld_stack_overflow]]'s chain, not attempted.

**Download time: Thorium has nothing to offer here — every one of its
levers grows the binary.** The real byte levers are ours, unrelated to
Thorium: zstd layer compression (`buildx --output
compression=zstd,force-compression`, needs consumer docker ≥23), ICU trim
(~10 MiB), and the 196 MiB apk runtime-libs layer. Unmeasured/parked as of
this audit; the actual duplicate-binary-layer bug found while investigating
this question shipped separately as PR #255 —
[[project_image_pull_is_bandwidth_bound]].

**"Parallel downloads"**: Thorium's `enable-parallel-downloading` flag is a
browser *file-download* feature (splits one user download into concurrent
HTTP range requests) — affects `page.download()` in a test, not image pull
or test speed. Noise for this investigation, same bucket as its DoH/FTP/NTP
patches.

**How to apply:** the ladder is `hard` (libc++ FAST + sized-dealloc) → `v3`
(AVX2+FMA) → `mllvm` (lore flags, optional) — queue after the current
parity campaign's chosen build ships and is read against official, same
sequencing note as [[project_chromium_hardening_removal_candidates]]. No
build has been dispatched from this audit yet; it is investigation only.
