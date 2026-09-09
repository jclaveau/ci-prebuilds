---
name: project_screenshot_row_is_frame_quantized
description: chromium and webkit quantize the runtime-probe screenshot row to whole 60Hz frames, so its ratio steps between small integer quotients — 1.00 means both arms fit one frame budget, not parity, and webkit's 0.66 is two frames against three
metadata:
  type: project
---

`page.screenshot()` waits on a frame commit on chromium and webkit, so the
probe's per-shot cost lands on multiples of 16.667 ms and the alpine/official
ratio can only take values near k/m for small integers. Measured on the n=10
runs (34289013835 / 34289022039 / 34289030252):

```
chromium official@7763   49.85-50.12 ms = 3.00 frames, locked
chromium ours@7763       49.87-55.12 ms = 2.99-3.31, at the edge of the budget
chromium official@9V74   33.32-50.07 ms = 2.00-3.00, sometimes fits TWO
chromium ours@9V74       58.59-66.83 ms = 3.52-4.01, never fits three
webkit   ours            31.65-35.31 ms = ~2 frames
webkit   official        46.46-54.82 ms = ~3 frames
firefox  both            13.68-22.96 ms = 0.82-1.38 frames, NOT quantized
```

**Why:** two standing readings were wrong. chromium `screenshot 1.00` on an EPYC
7763 is both arms inside the same 3-frame budget, not parity — ours is at the
edge (spilling to 3.31) and misses it entirely on a 9V74. And webkit's 0.66 from
the zlib-ng/libpng fix is a discrete budget crossing (2 frames vs 3), not a
continuous 34% speedup. Firefox is the only browser whose screenshot row
measures speed, which is why it is the only one that ever moved continuously
(0.68 -> 0.96 -> 1.01).

**How to apply:** never read a chromium or webkit `screenshot` delta as a
percentage. Divide the per-shot ms by 16.667 first and ask which frame bucket
each arm is in; a "regression" of 33% is one frame. The target for chromium is
to get under 50 ms/shot on a 9V74, where we sit at 58.6-66.8. Same family as
`locator_click` (2 frames x 100 = 3333.1) — see
[[project_ff_probe_pinned_rows_and_timer_grain]]. The Skia XR analysis in
[[project_chromium_screenshot_is_skia_highp]] is still the mechanism; this is
about what the row can and cannot report.

[[project_runtime_probe_rows_are_batches]] [[project_perf_probe_ratio_is_cpu_dependent]]
