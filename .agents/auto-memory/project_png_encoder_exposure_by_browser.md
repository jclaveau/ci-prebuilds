---
name: project_png_encoder_exposure_by_browser
description: only firefox paid the PNG size gap — webkit and chromium match official byte-for-byte on the canvas control, so libpng (not zlib, not musl) is what differed
metadata:
  type: project
---

Measured 2026-08-21 with `screenshot-encode-diagnosis.yml` (browser input), each
browser's own build against `mcr.microsoft.com/playwright:v1.62.1-noble`.
`png_canvas_control` is the row that decides it: a fonts-free deterministic
bitmap, and an identical `jpeg_q80_canvas_control` sha proves both sides
rasterized the same pixels.

| browser | our imaging libs | png_canvas_control | verdict |
|---|---|---|---|
| firefox | system libpng + system zlib | 40150 B vs 26801 B | **1.50x gap** |
| webkit | system libpng + system zlib | 6546 B vs 6546 B, sha differs | same size |
| chromium | **bundled** libpng + system zlib | 5049 B vs 5049 B, **same sha** | identical |

- Chromium takes Alpine's zlib (`replace_gn_files.py --system-libraries` lists
  `zlib`, not `libpng`) and still emits byte-identical PNG ⇒ **system zlib is
  output-neutral**, so firefox's gap was **libpng**. Two encoders, so this is
  converging evidence rather than a controlled swap.
- WebKit links Alpine's libpng and matches on size because *official WebKit
  links Ubuntu's libpng* — same library, different distro build. Firefox was
  Alpine's libpng against **Mozilla's bundled** one. The rule is "our libpng
  differs from the reference build's libpng", not "system libpng is worse".
- WebKit's control PNG is the same size with a different sha. Equal deflate
  output with differing bytes is not a compression-strength difference —
  chunk-level (metadata, or an equally-compressible filter choice). Unexplained;
  the probe keeps digests, not buffers.

**Chromium timings are unusable here**: nearly every cell lands at 33.0–33.4 ms
including a 16x16 clip (webkit does that in 4.5 ms). That is the ~30 fps
compositor cadence, not encode cost — the one "significant" row (jpeg control
0.50x) is a half-frame alignment, not a finding. Read bytes, not milliseconds,
for chromium.

**How to apply:** before blaming musl for an output-bytes difference, ask which
copy of the library each side links — see [[project_ff_png_encoder_gap]] and
[[project_alpine_browser_perf_vs_glibc]]. Probe with
`gh workflow run screenshot-encode-diagnosis.yml -f browser=<b> -f image_a=… -f
image_b=official -f browser_rev=<PW browsers.json rev>`.
