---
name: project_chromium_faststring_moves_layout_text
description: the AVX2 string shim moves chromium layout_text 1.14x -> 1.09x on a one-variable same-run leg (not just launch), controls flat and the gate non-vacuous; shipped in PR #198, and TP's paths-ignore needed a fourth negation for it
metadata:
  type: project
---

Run 34347324868, Xeon 6973P-C. Three legs of `chromium-gap-probes` ran the
SAME from-source artifact, differing only by what was preloaded.

| leg | layout_text | ×off | layout_boxonly | ×off | typed_array_fill | typed_array_move |
|---|---|---|---|---|---|---|
| official | 597.3 | 1.00 | 160.7 | 1.00 | 1.00 | 1.00 |
| ours | 680.4 | 1.14 | 192.0 | 1.19 | 1.00 | 0.99 |
| ours + fast-string | 652.4 | **1.09** | 189.7 | 1.18 | 1.02 | 0.99 |

**-4.1% on `layout_text`** from replacing musl's `memcpy`/`memset`/`memcmp`/
`strlen`/`memmove` with AVX2 versions. This is the first row other than
`launch` the shim moves, and it is a clean reading: one variable, one image,
one run, one CPU, both `typed_array_*` controls flat (they are V8-internal and
never call libc, [[project_chromium_musl_string_routines]]), 7 processes
witnessed loading the shim, and the leg's own corrupted-shim mutation was
caught so the gate is not vacuous.

`layout_boxonly` barely moves (1.19 -> 1.18). The two kernels differ — text
layout is where the string work lives.

**Shipped** as PR #198 (merged 2026-09-09): `faststring/` beside fastfmod and
zlib-ng, compiled in a `faststring-build` stage, `run-gate.sh` gating the
build, and the chromium launch shim changed from `unset LD_PRELOAD` to
`export LD_PRELOAD=/usr/lib/libfaststring.so`. Compile WITHOUT `-mavx2` — the
dispatcher must stay AVX2-free and the AVX2 bodies carry
`__attribute__((target("avx2")))`, guarded by `__builtin_cpu_supports` and
disablable with `CHS_FAST_STRING=0`.

**`test-and-publish.yml` needed a fourth `paths-ignore` negation** for
`playwright/alpine-browsers/chromium-headless-shell/faststring/**`. It did NOT
block #198 — the same commit edits `playwright/Dockerfile.alpine`, which is
outside the ignored prefix and dragged the build in — but a faststring-only
follow-up would have been the #167 shape exactly.
[[project_tp_paths_ignore_ships_nothing]]

**RETRACTED 2026-09-09 — measured in the shipped image, the shim is a net loss
and the layout_text win does not exist.** Everything above was measured by
preloading the shim over the artifact at `image_ours`, which is a DIFFERENT
build from the consumer image: on a Xeon 8573C (run 34352337495) the two read
`layout_text` **1.40x and 1.14x** against the same official arm on the same
runner. A delta measured on one says nothing about the other.

`libfaststring.so` reads `CHS_FAST_STRING` at load, so the published binary is
its own control. Runs 34355411280 (Xeon 8370C) and 34357346361 (EPYC 7763,
passes ordered on/off/on):

| row | shim on | shim off |
|---|---|---|
| `launch` 7763 | **1.43x** | 1.36x |
| `launch` 8370C | **1.35x** | 1.28x |
| `layout_text` 7763 | 1.30x | 1.29x |

`launch` is worse with the shim on BOTH machines, and it is the row we are
furthest behind on. Mechanism: a preload adds a DSO, and `launch` is bound by
the closure — musl binds every symbol in every object, so a 66th object costs.
[[project_chromium_launch_is_the_musl_loader]] Unloaded in PR #201; source and
gate kept, because the kernels have no size threshold — under 32 bytes they run
a byte-at-a-time tail where musl copies words.

**The trap that nearly caused a wrong revert.** The FIRST self-control run was
unbracketed — shim-on pass then shim-off pass, in sequence — and reported the
`typed_array` controls 34-37% WORSE with the shim, which read as a serious
regression with a tidy code-level explanation ready to hand. Bracketed, the
same kernel is 44% FASTER with it. A pair of passes run back to back in one job
cannot separate the variable from drift over the job; run the first arm again
afterwards and compare against the mean, and treat the two same-arm passes
disagreeing by more than the effect as "this job says nothing".
[[feedback_verify_ab_varied_the_variable]]
