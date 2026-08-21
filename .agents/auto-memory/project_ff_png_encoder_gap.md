---
name: project_ff_png_encoder_gap
description: musl Firefox emits PNGs 1.50x larger and 1.31x slower than PW's official build from a byte-identical bitmap — system libpng/zlib, not musl or PGO
metadata:
  type: project
---

Our musl Firefox screenshots at 0.68x vs `mcr.microsoft.com/playwright:v1.62.1-noble`
(runtime probe, run 32460180480). The whole gap is full-viewport PNG encode.

Measured (`ff-screenshot-diagnosis`, run 32461286072), canvas control, no fonts:

| case | alpine | official |
|---|---|---|
| png_canvas_control | 28.2 ms / 40150 B | 21.5 ms / 26801 B |
| jpeg_q80_canvas_control | 21.0 ms / 41079 B | 18.8 ms / **41079 B, same sha** |
| png_clip_16x16 | 8.8 ms | 8.2 ms |

- Identical JPEG bytes+sha ⇒ **both builds rasterize the same pixels**. The first
  run without this control was confounded: the text page uses distro fonts, and
  different antialiasing alone makes a bitmap bigger AND slower to deflate.
- From that identical bitmap our PNG is 1.50x larger ⇒ a different encoder or
  different deflate settings. **Optimisation flags cannot change output bytes**,
  so PGO/LTO are ruled out for the SIZE (they can still cost time).
- The 16x16 clip is at parity ⇒ capture, readback and transport are fine.

Cause: aports' mozconfig sets `--with-system-png` + `--with-system-zlib` (Alpine
zlib 1.3.2, libpng 1.6.58); Mozilla ships its own copies. `--with-system-jpeg`
already matches the reference byte-for-byte.

Secondary: aports enables PGO inside its APKBUILD `build()`, which we never run —
see the note in `firefox/mozconfig.overlay`. Our FF is LTO-but-not-PGO.

**How to apply:** arm `perf/firefox-bundled-imaging` (run 32462261885) drops the
two lines. Decisive readout = the canvas control's PNG byte count: near 26801 B
means the encoder was the cause; still ~40150 B means it wasn't, and PGO is next.
Bundling fights this repo's system-lib/dedup direction, so it is an experiment,
not a decided fix. See [[project_ff_build_two_pass_cbindgen]].
