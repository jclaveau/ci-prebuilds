---
name: project_png_encoder_exposure_by_browser
description: only firefox paid the PNG size gap; webkit and chromium match official byte-for-byte on the canvas control — but libpng-vs-zlib is NOT yet separated (zlib-only arm in flight)
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
  `zlib`, not `libpng`) and still emits byte-identical PNG. **This is weaker than
  it looks and I over-claimed it once**: it compares two *C zlib derivatives*,
  which agree by construction, while Mozilla's tree also builds **zlib-rs**
  (`Compiling zlib-rs v0.6.3` in the arm's log) whose deflate output need not
  match. The firefox arm deleted `--with-system-png` AND `--with-system-zlib`
  together — the log shows both `media/libpng` and `modules/zlib/src` compiling —
  so the pair is established, the half is not. `perf/firefox-bundled-zlib`
  (run 32486920455) drops only zlib to split them. See
  [[feedback_control_excludes_one_mechanism]].
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

**2026-08-21:** libpng-vs-zlib is separated — the zlib-only arm left `png_canvas_control` at 40150 B (unchanged), so libpng carries the whole gap. See [[project_ff_png_encoder_gap]].

**2026-08-27 — for chromium, byte identity exonerates the BYTES and says nothing
about the TIME, and the "chromium timings are unusable" rule above is too broad.**
Measured locally, both containers back to back, chromium 151.0.7922.34 both sides:

| case | ours | official |
|---|---|---|
| `png_viewport` | 54.1 / 54.7 / 56.9 ms | 42.9 / 33.6 / **33.4** |
| `jpeg_q80_viewport` | ~33 (frame floor) | ~33 (frame floor) |
| `png_clip_16x16` | 33.4 (floor) | 33.2 (floor) |

The JPEG full-viewport shot is AT THE FLOOR on our side — same capture, same
readback, same transport, same pixel count, only the codec differs. So
capture/readback is **exonerated for chromium**, the opposite of firefox
([[project_ff_png_encoder_gap]]). The 16x16 PNG is at the floor too, so it is not
per-call PNG overhead. The whole ~21 ms overrun is full-viewport PNG deflate.

At symbol level: `deflate`/`deflateInit2_`/`crc32`/`adler32` are all `U` on ours
(imported from Alpine's plain madler zlib 1.3.2 — no PCLMUL crc32, no SSSE3
adler32, no SSE2 slide_hash) and **absent entirely** from official, which bundles
chromium's SIMD zlib. The bundled copy is output-identical to madler's *by
construction*, which is exactly why the same-sha row above reads as exoneration
and is not one.

Sizing the lever: LD_PRELOADing a zlib-ng-compat `libz.so.1` into the same binary
took `png_viewport` 54.7 -> 50.0 ms, i.e. **~4.7 ms of the ~21 ms overrun (22%)**,
with PNG bytes and sha unchanged (so the lever was provably connected and
output-neutral). The repo's AVX2 string shim buys ~15% more, not additive.

**Method: `png_canvas_control` is BIMODAL on chromium** — 34.1 / 35.0 / 46.9 ms
across identical baseline runs. A first A/B read 46.9 -> 35.7 and looked like a
clean 82% win; the repeat reversed it. Only `png_viewport` is stable enough to
carry a chromium timing claim; the canvas control stays the right instrument for
BYTES. [[feedback_check_reference_stability_across_runs]],
[[feedback_match_instrument_to_effect_size]]
