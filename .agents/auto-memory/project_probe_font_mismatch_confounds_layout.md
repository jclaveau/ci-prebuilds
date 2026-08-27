---
name: project_probe_font_mismatch_confounds_layout
description: the runtime probe's alpine and official arms resolve completely different fonts — ours FreeSans, official's a CJK face where serif/sans-serif/unknown all collapse to one — so layout, dom_churn, screenshot and goto_* compare text shaping as well as engine speed
metadata:
  type: project
---

`runtime-probe.cjs`'s fixture builds 800 pad divs of text plus 100 buttons and
sets **no font-family**, so every arm lays out whatever fontconfig picks. The
`layout` kernel forces 2000 full-document reflows, which re-measures that text,
so font shaping is inside the timed loop.

Measured in the two images (deterministic, no timing involved):

| | alpine (ours) | official (MCR noble) |
|---|---|---|
| `fc-match sans-serif` | `FreeSans.otf` | **`wqy-zenhei.ttc` (WenQuanYi Zen Hei, CJK)** |
| default / `serif` width | 208.03 px | 232.18 px |
| `sans-serif` width | 224.52 px | 232.18 px |
| unknown-face width | 208.03 px | 232.18 px |
| `monospace` width | 230.40 px | 192.00 px |

On official, `serif`, `sans-serif` and a deliberately-missing face all give the
**same** 232.18 px — every generic family collapses onto one CJK face. On ours
they differ, i.e. we resolve distinct real faces. The two arms are laying out
different glyphs from different fonts.

**But it does NOT explain the `layout` deficit — I checked, and my first read
was wrong.** An alternating font-family run suggested ~25%, but its arms
overlapped completely (one arm spanned 181-265 ms on a laptop that parallel
agents were loading), so that was noise read as signal. The clean design is a
text page vs a box-only page (explicit width/height, no text) measured
INTERLEAVED in one process, which makes the ratio internal to each image:

| image | text page | box-only page | text/box |
|---|---|---|---|
| alpine | 168 ms | 177 ms | **0.949** |
| official | 194 ms | 182 ms | **1.066** |

Both sit at ~1.0. The kernel dirties one element's width and reads
`offsetHeight`; Gecko reflows the dirty subtree and reuses the cached text runs
for the 800 pad rows, so shaping is not re-paid per iteration. So `layout`
1.087 is a genuine build-quality deficit and LTO remains the right lever for it.

The mismatch still stands as a real difference and still matters for the rows
that PAINT or lay out fresh text — `screenshot`, `dom_churn`, `goto_*` — and it
is worth pinning the fixture's font-family regardless, because "the two arms
render different glyphs" is not a property a parity benchmark should have.

**How to apply:** any cross-image comparison whose workload contains text needs
the font checked first — `fc-match` plus one `getBoundingClientRect().width` on
a fixed string costs seconds and is noise-free.
[[project_runtime_perf_probe]], [[feedback_verify_ab_varied_the_variable]]
