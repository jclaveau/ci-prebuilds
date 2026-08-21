---
name: wk-screenshot-format-ignored
description: RESOLVED — the WebKit webp/jpeg screenshot failures were Page.snapshotRect ignoring the requested format and always returning PNG, not a webp decoder, missing lib or Skia encoder gap
metadata:
  type: project
---

**Supersedes the earlier "webp dead hypotheses" note.** Root cause found:

`playwright-core` asks for the format over the wire —
`Page.snapshotRect({ format, quality })` — and on **Linux it does not re-encode
client-side** (`wkPage.ts` recodes PNG→webp only on darwin). It then strips the
`data:image/<fmt>;base64,` prefix **without checking the mime**, so whatever we
encode is returned as if it were the requested format. The v1.62.1 patch series
adds only `omitDeviceScaleFactor` to `snapshotRect` and still hardcodes
`encodeDataURL(..., "image/png")` — so every screenshot came back PNG:

- webp → PW's decoder rejects PNG bytes → `Error: WebP decode failed`
- jpeg → no `0xFFD8` header → `Error: SOI not found`
- quality tests → PNG ignores quality, so 0 and 100 give identical bytes
- png tests passed throughout, which is exactly why this read as webp-specific

**Hypotheses that were wrong** (do not re-walk): missing runtime libwebp (the
packages are stripped but installing them changed nothing); a missing dev package
at cmake configure (`Dockerfile.port` inherits source-prep, which has
`libwebp-dev`); and missing Skia encoders — `SkJpegEncoder`/`SkWebpEncoder`/
`SkPngEncoder` are all compiled in and already map quality 0..1 → 0..100.

Fix: plumb `format`/`quality` through `snapshotRect` + a `Page.ImageFormat` enum,
and backport upstream's `webpEncoderOptions` so quality 1.0 selects lossless
(the pinned base never set `fCompression`, so "lossless by default" would still
fail). Redundant once the base moved — main's series carries it
([[project_pw_patch_series_base_pairing]]).
