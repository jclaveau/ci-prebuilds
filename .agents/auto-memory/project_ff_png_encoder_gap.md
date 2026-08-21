---
name: project_ff_png_encoder_gap
description: RESOLVED — musl Firefox's 1.50x-larger PNGs were Alpine's system libpng/zlib; bundling Mozilla's copies makes the canvas control byte- and sha-identical to official
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

**RESOLVED 2026-08-21** — arm `perf/firefox-bundled-imaging` (build 32462261885,
diagnosis 32481799551) deletes the two mozconfig lines. The canvas control goes
**40150 B → 26801 B with sha 2768ce17d3c727d9, byte-identical to official**, and
its 0.76x timing — the only significant row in the control run — becomes n.s.
The encoder was the whole cause; PGO is not implicated in the size and no longer
needs to be tried for it.

| case | control (system) | arm (bundled) | official |
|---|---|---|---|
| png_canvas_control | 40150 B | **26801 B, same sha** | 26801 B |
| png_viewport | 25018 B | 12188 B | 10875 B |

`png_viewport` cannot reach parity — the page uses distro fonts, so the bitmaps
genuinely differ — but it drops from 2.30x official's size to 1.12x.

Cost: **+122,670 B compressed** (136.5 → 136.6 MiB), and conformance-firefox
stayed 20/20 with conformance-runtime-parity green.

**How to apply:** bundling fights this repo's system-lib/dedup direction, so
whether to land it is the user's call, not a foregone conclusion — the evidence
is in, the decision is not. The measurement recipe generalises: for any
"our output bytes differ" question, use the canvas control (identical JPEG sha
proves the bitmap is shared) and read the byte count, never the timing.
See [[project_ff_build_two_pass_cbindgen]], [[feedback_prove_the_lever_is_connected]].
