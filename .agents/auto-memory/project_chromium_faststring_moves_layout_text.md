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
