---
name: project_chromium_trace_gap_is_uniform
description: CDP tracing (trace-probe.cjs) says the chromium gap is UNIFORM across Blink phases — per-event self-time SHARES match official within 0.85-1.2 for style, layout, paint, IPC and scheduler on goto_warm/click_force/layout, so no subsystem owns it; the one consistent outlier is DisplayItemList::Raster (share 1.4-2.0x, Skia); on the dev box wall ratios are unreadable (int_math swings 1.50 -> 0.83 with arm order) — read shares, never walls
metadata:
  type: project
---

Issue #249 item 3, 2026-09-15, dev box, `--cpuset-cpus=0-4`, shipped alpine
image vs `mcr.microsoft.com/playwright:v1.62.1-noble`, `browser.startTracing`
with devtools.timeline/blink/v8.execute/toplevel/cc around the runtime-probe
scenarios, 3 iterations each, self time per event name with children
subtracted (`playwright/bench/trace-probe.cjs`, compared by
`trace-compare.py`).

**Shares are flat.** goto_warm: performLayout 15.8/16.7 %, ShapeText 8.0/7.5,
RunTask 14.9/13.7, mojo 4.9/6.0. layout kernel: performLayout 16.4/14.1,
recalcStyle 10.5/8.8, Layout 19.7/23.0, UpdateLayoutTree 6.4/6.6.
click_force: RunTask 27.0/26.3, mojo 15.8/17.6, Paint 6.5/5.8. Same picture
with the arm order reversed. A build that lost one subsystem would show one
share doubled; this is every phase paying the same factor — the signature of
a global cause (code layout / instruction fetch,
[[project_chromium_layout_gap_is_frontend_fetch]]), not a subsystem bug.

**Outlier:** `DisplayItemList::Raster` share 1.44-1.98x on goto_warm and
click_force, `Paint` 1.1-1.4x — Skia raster, the same family
[[project_chromium_screenshot_is_skia_highp]] named. The only localised lead
tracing adds.

**Dev-box trap.** The pure-JIT controls read int_math 1.50 / libm_fmod 1.45
with alpine first and 0.83 / 0.99 with official first: whichever arm runs
first is slower by ~20 % (thermal/turbo on the laptop). Wall ratios from a
single-order box run are therefore meaningless; per-scenario SHARES survive
it. On GHA the same controls are 1.00, so wall ratios there are fine.

**How to apply:** don't spend a chain on "fix style recalc" or "fix layout";
tracing has no subsystem to hand. If Skia raster is ever attacked, this is
the second independent sighting.
