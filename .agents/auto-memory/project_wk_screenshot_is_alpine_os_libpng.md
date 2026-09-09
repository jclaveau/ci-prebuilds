---
name: project_wk_screenshot_is_alpine_os_libpng
description: RESOLVED 2026-09-08 — WebKit screenshot's +2.77ms/shot gap is Alpine's -Os libpng+zlib, not capture/readback; fixed with an LD_PRELOAD zlib-ng (ZLIB_COMPAT=ON, source-built) beside mimalloc/fastfmod, screenshot 1.06->0.69 (PR #187)
metadata:
  type: project
---

`runtime-probe.cjs`'s `screenshot` row is a batch of 10 shots per sample
([[project_runtime_probe_rows_are_batches]]) — the real gap is **+2.77
ms/shot** (49.15 vs 46.38), not the ~28 ms an early unit slip invented.

**Capture/readback exonerated by profile, not argument.** A `perf record -a
--sudo` (unprivileged perf can't read `/proc/<pid>/maps` on a root-owned
container) differential over the screenshot kernel: no Skia, GL, EGL,
gallium, cairo or GStreamer DSO carries measurable time in our arm at all;
our arm takes FEWER kernel samples (386 vs 917) and FEWER page faults
(120,242 vs 274,011) than official over the same window. Whole-PNG cost is
libz+libpng: **81% of the shot** (41.2 of 50.8 ms WebProcess CPU), offset by
less time in WebKit itself (-0.75ms) and less kernel time (-1.58ms).

**Ruled out before the real cause, in order** (keep these — each was the
leading theory at some point):
- **zlib-ng in Ubuntu** — dead. Noble ships plain zlib, zero `zng_`/
  `crc32_fold`/`chunkcopy` markers in the .so.
- **SIMD dispatch** — dead. Neither libz has pclmulqdq CRC; neither libpng
  has SSE2 filter kernels (official's 383 SSE2 instructions are struct-copy
  inlining in `png_set_rgb_to_gray`/`png_malloc`/`deflateParams`, not codec
  paths).
- **Hardening** — dead, and in the wrong direction: our canary counts (32
  libz / 253 libpng) are within 5% of official's (24/240), and we import
  FEWER `__*_chk` symbols than official, not more.

**Cause: `-Os`.** Alpine's `abuild.conf` exports `CFLAGS="-Os"`; zlib's
APKBUILD overrides it to `-O2`, libpng's does not. Fingerprint: our libpng
16-byte-aligns 14 of 276 functions (5%); official's aligns 246/246 (100%).
A/B on the same host (min-of-N, alternating passes — a loaded desktop needed
min-of-25 to be readable, single-shot medians are not trustworthy):

| kernel | Alpine distro (`-Os`) | same source, `-O2`/`-O3` | official |
|---|---|---|---|
| libpng filter-only | 61.8 ms | 50.2 ms (`-O2`) | 49.7 ms |
| zlib crc32 (4.1 MB) | 2.807 ms (`-O2` already) | 1.380 ms (`-O3`) | 1.56 ms |
| zlib deflate L6 | 173.3 ms | 172.8 ms (`-O3`) | 185 ms |

Deflate itself is already ahead of official and flag-insensitive — the whole
gap is libpng's filters plus crc32.

**Fix: LD_PRELOAD zlib-ng**, the same interposition pattern as mimalloc and
fastfmod. **Alpine's `zlib-ng` apk package cannot be used** — it ships only
the native `libz-ng.so.2` with `zng_`-prefixed symbols and zero plain
`deflate`, so it interposes nothing (verified in a throwaway `alpine:edge`
container before assuming). Built from source with
`-DZLIB_COMPAT=ON -DBUILD_SHARED_LIBS=ON` instead, single source of truth at
`playwright/alpine-browsers/webkit/zlib-ng/build-zlib-ng.sh`, run by BOTH the
consumer `Dockerfile.alpine` and the conformance runner (not an inline `RUN`
duplicated twice — that's how the aports pkgver rule drifted in two of three
copies). Non-vacuous smoke: `zlibVersion()` must contain "zlib-ng", plus a
CRC-32 known vector and a round-trip — never byte equality, since zlib-ng
deliberately emits different (2% smaller at L6) bytes. `WK_ZLIB_NG=0` env
flag drops just that preload entry so an A/B can share one runner.

Full PNG encode, source-built local A/B: `1.10x official -> 0.73x`
(crc32 11x, adler32 9.6x, deflate 2.35x). n=10 in-browser, control in the
same job: **`screenshot` 1.01 -> 0.66**.

**Byte-change risk checked against PW 1.62.1 sources, not assumed nil.**
`getComparator('image/png')` decodes via `PNG.sync.read` and diffs pixel
planes (`pixelmatch`/`ssim-cie94`); `toMatchSnapshot.ts` picks the comparator
off the snapshot's file EXTENSION, so every `*.png` `toMatchSnapshot`/
`toHaveScreenshot` takes the decoded-pixel path; zero `createHash`/`md5`/
`Buffer.compare` in the browser suites; the only PNG-adjacent `.byteLength`
assertions are on jpeg/webp quality, not PNG (PNG rejects a `quality` option
outright); every screenshot `.equals()` compares two shots from the SAME
encoder in the SAME run. Verdict: would not break.

See [[project_conformance_runner_mirrors_consumer]] for the second gate this
fix had to clear before merge — the conformance runner didn't carry the new
preload by default and doesn't run on `pull_request` at all.
