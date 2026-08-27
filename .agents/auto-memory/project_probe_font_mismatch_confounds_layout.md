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

**Size of the confound:** alternating font-family inside ONE page in ONE process
(so machine noise hits every arm equally) moves the layout kernel by up to ~25%
— larger than the 8.7% alpine-vs-official `layout` deficit being chased. The
exact figure was not pinned because the laptop was oversubscribed by parallel
agents, but the direction and magnitude are established and the `fc-match` /
width table above needs no timing at all.

**So `layout` 1.087 is not purely a build-quality number**, and neither are
`dom_churn`, `screenshot` or the `goto_*` rows. The fix is in the fixture, not
in either image: pin an explicit `font-family` (or a web font served by the
probe's own http server) so both arms shape identical glyphs. Matching the
images' font packages instead would work but changes rendering, so it is a
conformance question, not a free one.

**How to apply:** any cross-image comparison whose workload contains text needs
the font checked first — `fc-match` plus one `getBoundingClientRect().width` on
a fixed string costs seconds and is noise-free.
[[project_runtime_perf_probe]], [[feedback_verify_ab_varied_the_variable]]
