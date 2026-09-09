---
name: project_three_model_parity_state
description: The 3-CPU-model x 2-draw campaign of 2026-09-09 — firefox and webkit are AT or under parity on every row on every model, chromium is the sole remaining gap, and its layout ratio is worst on the 7763
metadata:
  type: project
---

First campaign run with `scripts/sample-cpu-models.sh` (3 rounds, runs
34296944932 / 34298331469 / 34299715940, image
`jclaveau/alpine-dood-playwright:latest`, n=10, 500 probe JSONs). Report kept at
`tmp/perf-3model-2026-09-09.md`.

**The parity goal is met for two of three browsers.** On EPYC 7763, EPYC 9V74
and Xeon 8573C alike:

- **firefox** — every row <= 1.00 except `layout` 1.05 and `screenshot` 1.05 on
  the 8573C alone. `dom_churn` 0.75, `libm_fmod` 0.52-0.62.
- **webkit** — every row <= 1.05; the only rows above 1.00 are `click_force`
  1.03-1.05. `screenshot` 0.65-0.72, `layout` 0.79-0.88.
- **chromium** — the whole residual. Per model (7763 / 9V74 / 8573C):
  `launch` 1.45 / 1.45 / 1.40, `layout` 1.62 / 1.28 / 1.24,
  `goto_warm` 1.26 / 1.23 / 1.19, `goto_cold` 1.21 / 1.20 / 1.22,
  `screenshot` 1.00 / 1.22 / 1.00.

**What the cross-model scaling adds, which no single run could.** The `xoff`
ratio divides the runner out and therefore hides WHICH arm moved; scaling each
arm against its own 7763 median does not:

- `launch` scales identically on both arms (1.02 vs 1.02, 0.71 vs 0.74), so
  chromium's launch gap is a constant multiplicative factor, CPU-independent —
  exactly the shape [[project_chromium_launch_dso_closure]] predicts.
- `layout` parts (ours 0.77 / 0.59, official's 0.97 / 0.78): our build gains
  MORE from faster silicon, so **1.62 is a 7763 worst case**, not the number.
  Quote the model or quote the range.
- `screenshot` parts on the 9V74 pair only (1.22 vs 1.00), which is
  [[project_screenshot_row_is_frame_quantized]] and not a speed reading: 7763
  and 8573C have both arms inside one budget (50.0 and 33.3 ms/shot), the 9V74
  has official at 3 frames and ours at 61.2 ms/shot, spilling to 4.

**The concrete open target**: chromium `screenshot` under 50 ms/shot on a 9V74.

[[project_perf_probe_ratio_is_cpu_dependent]]
[[project_chromium_screenshot_is_skia_highp]]

**CORRECTION 2026-09-09, run 34347324868 — `launch` is NOT CPU-independent.**
A fourth draw, a **Xeon 6973P-C**, reads the consumer image at **1.60x**
against the 1.40-1.45 recorded on 7763 / 9V74 / 8573C. The ratio gets WORSE on
the wider Intel core, which fits the loader root cause
([[project_chromium_launch_is_the_musl_loader]]): musl's symbol binding is
serial pointer-chasing through the loaded-object list and gains little from
ILP, while official's compute-bound path does. Quote `launch` as
1.40-1.60 across CPUs, never as a single number.

Same draw, same image: `layout` **1.11x** — so the 1.62 on the 7763 is
confirmed a worst case and not the norm. `screenshot` 498.1 vs 333.1 is 30
frames against 20 ([[project_screenshot_row_is_frame_quantized]]), not speed.
`libm_fmod` 1.00x, `int_math` 0.90x (we win), `locator_click` pinned at 3333
both sides.
