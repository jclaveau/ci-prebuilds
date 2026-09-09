---
name: project_chromium_launch_is_the_musl_loader
description: chromium's launch gap is the musl dynamic loader — 71% of the whole CPU delta per launch, while the browser binary itself is at parity; the fix is a smaller DSO closure, and the static --version probe undercounts it 3x because launch() execs three processes
metadata:
  type: project
---

First profile of the `launch` row, run 34305385512 (2026-09-09, both arms in
one job, 30 s `perf record -a -G /`, 80 s steady-state loop). The kernel
reproduces the row: medians **126.8 ms ours / 90.7 ms official = 1.40x**,
matching perf-probe's 1.40-1.45 across three CPU models.

Normalised per launch over the record window:

| per launch | ours | official | delta |
|---|---|---|---|
| total CPU | 161.8 ms | 110.3 ms | +51.5 |
| **dynamic loader** | **49.4 ms** (30.54%) | **12.9 ms** (11.65%) | **+36.6** |
| main binary | 15.6 ms (9.64%) | 16.0 ms (14.49%) | -0.4 |
| kernel | 85.4 ms (52.81%) | 68.9 ms (62.51%) | +16.5 |

**The loader is 71% of the entire CPU delta and the browser's own code is at
parity.** Nothing in Blink, V8 or Skia is implicated in this row.

**Why the static probe undercounted it 3x.** `chrome-headless-shell --version`
measures ONE exec and reads +5.5 ms
([[project_chromium_launch_dso_closure]]). `launch()` execs the browser, the
zygote and a renderer, so the closure is paid about three times — which is how
+5.5 becomes +36.6. A one-exec probe is the wrong unit for a
multi-process launch; do not price this row with one again.

**The mechanism is symbol binding, not relocation volume.** 65 DSOs vs 51,
`closure-symbol-relocs` **13,373 vs 6,739 (1.98x)**, while
`closure-relative-relocs` are FEWER on our side (0.91x). musl binds every
symbol reference in every object at load; glibc binds what is called.

**So `USE_SYSTEM_LIBS` is back on**, having been talked down twice. It is the
only lever that shrinks the closure. Trimmed to what cannot be bundled —
fontconfig (musl lacks `initstate_r`), freetype/harfbuzz (shared text stack),
libdrm (host kernel interface), openh264 (bundled path unexercised) — on
`perf/chromium-unbundle-libs`, chain 34307272009, branched off main so the
main chain 34301104893 (stack-protector parity alone) is its control.

**Non-vacuity witness for the trim**: ninja's total target count. The unbundle
chain builds **39365** targets against main's **38707** (+658) — bundling
twelve libraries back brings their own build graphs with them.
`replace_gn_files.py` prints nothing on success, and the setup-stage gn count
(31648 vs 31599) is too small a delta to trust, so read the ninja total from
r1's log instead.

[[project_chromium_use_system_libs_verdict]] [[project_three_model_parity_state]]
