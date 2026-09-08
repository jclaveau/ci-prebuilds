---
name: project_wk_screenshot_is_alpine_os_libpng
description: webkit's screenshot gap was Alpine building libpng at -Os, not SIMD or hardening; zlib-ng preload takes PNG encode 1.10x -> 0.73x and the row 1.06 -> 0.69
metadata:
  type: project
---

`screenshot` sat at 1.06x. A perf record of WPEWebProcess (run 34207799987,
normalized by round rate) put **81% of a shot in libz + libpng** and the whole
delta there:

| DSO | ours | official | delta |
|---|---:|---:|---:|
| libpng16 (1.6.58 / 1.6.43) | 17.374 ms/shot | 15.484 | **+1.890** |
| libz (1.3.2 / 1.3) | 23.826 | 22.446 | **+1.380** |
| libWPEWebKit | 7.189 | 7.935 | -0.746 |
| kernel | 1.206 | 2.788 | -1.582 |

Capture/readback is **exonerated by that profile**: no Skia, GL, EGL, gallium,
cairo or GStreamer DSO carries measurable time in our arm, and we take FEWER
kernel samples (386 vs 917) and page faults (120,242 vs 274,011) than official.

**Cause: Alpine's `abuild.conf` exports `CFLAGS="-Os"` and libpng's APKBUILD
does not override it** (zlib's does, to `-O2`). Fingerprint: our libpng aligns
**14 of 276** functions to 16 bytes, Ubuntu's aligns **246 of 246**. Same
source at `-O2` takes the filter kernel 61.8 -> 50.2 ms vs official's 49.7.

Ruled out first, all by inspecting the two artifacts:
- **Ubuntu is NOT running zlib-ng** — zero `zng_`/`crc32_fold`/`chunkcopy`
  markers. This was the leading theory.
- **Not SIMD dispatch** — neither libz has pclmul CRC, neither libpng has SSE2
  filter kernels; official's 383 SSE2 instructions are struct-copy inlining.
- **Not hardening** — canaries 32/253 ours vs 24/240 official, and we import
  FEWER `__*_chk` (1/1 vs 3/4). Unlike chromium
  ([[project_chromium_perf_record_first_read]]), SSP is not it here.

**Fix (PR #187): LD_PRELOAD zlib-ng built `ZLIB_COMPAT=ON`**, the
mimalloc/fastfmod pattern. PNG encode 1.10x -> 0.73x (crc32 11x, adler32 9.6x,
deflate 2.35x); the probe row went **1.06 -> 0.69 at n=10**. Alpine's own
`zlib-ng` apk cannot do this: it ships only `libz-ng.so.2` with `zng_`-prefixed
symbols and no plain `deflate`, so preloading it interposes nothing — hence the
source build in `playwright/alpine-browsers/webkit/zlib-ng/build-zlib-ng.sh`.

Note deflate itself was already AHEAD of official (173.3 vs 185 ms) and is
flag-insensitive; the gap was libpng's filters and crc32.

**Why:** [[project_png_encoder_exposure_by_browser]] recorded webkit as "same
size, sha differs" and stopped at bytes. Byte identity says nothing about time —
the same lesson chromium taught there.

**How to apply:** zlib-ng emits a ~2% smaller stream, so anything asserting
screenshot bytes moves. PW 1.62.1 asserts none — `getComparator('image/png')`
decodes via `PNG.sync.read` and compares pixels, `toMatchSnapshot` picks the
comparator off the FILENAME EXTENSION, the only `byteLength` assertions are
jpeg/webp quality ones, and every screenshot `.equals()` compares two shots from
the same encoder in the same run. Before suspecting musl, check the distro's
optimisation flags for the specific library.
