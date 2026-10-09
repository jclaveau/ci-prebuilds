---
name: project_chromium_faststring_moves_layout_text
description: the AVX2 string shim moved layout_text but RETRACTED (measured on the wrong artifact; real A/B shows launch WORSE with it on 2 CPUs) and unloaded in PR #201, shim kept disabled in the image; REOPENED 2026-09-23 via PR #306's 3-arm none/loaded-off/loaded-on design to target goto_warm/click_force's musl-memset finding instead of launch/layout_text; CLOSED AGAIN same day — noise floor ≥10% swamps the claimed ≤3.6% signal, no ship
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

**STATUS 2026-09-23 — repurposed for the nav/input residual.** The shipped
shim (source + gate kept, `CHS_FAST_STRING=0` disables it, still installed
into the image) is exactly the mechanism
[[project_chromium_click_force_never_profiled]]'s profile now motivates: it
found musl scalar `memset`/`memcpy` costing `goto_warm` +1.55pp and
`click_force` +0.76pp — rows this file's original A/B never measured (only
`launch` and `layout_text` were read). New three-arm design, PR #306
(`perf/chromium-faststring`, superseding a stale same-named branch that
made the first push non-fast-forward — PR #305 was abandoned):

| arm | preload | isolates |
|---|---|---|
| `none` | — | baseline |
| `loaded-off` | `libfaststring.so` + `CHS_FAST_STRING=0` | DSO-closure cost alone (the thing that made `launch` worse in the retraction below) |
| `loaded-on` | `libfaststring.so` | + string-code effect |

`none→loaded-off` prices the closure; `loaded-off→loaded-on` prices the
string code. Ship only if the second beats the first — this design can't
repeat the original episode's mistake of crediting the string code with a
`launch` cost that was really just a 66th DSO in the closure. Five passes
ordered none/off/on/off/none so drift shows as a same-arm disagreement.

**The trap that nearly caused a wrong revert.** The FIRST self-control run was
unbracketed — shim-on pass then shim-off pass, in sequence — and reported the
`typed_array` controls 34-37% WORSE with the shim, which read as a serious
regression with a tidy code-level explanation ready to hand. Bracketed, the
same kernel is 44% FASTER with it. A pair of passes run back to back in one job
cannot separate the variable from drift over the job; run the first arm again
afterwards and compare against the mean, and treat the two same-arm passes
disagreeing by more than the effect as "this job says nothing".
[[feedback_verify_ab_varied_the_variable]]

**CLOSED AGAIN 2026-09-23 — the 3-arm PR #306 run's own artifact, read
without redispatching.**

```
launch: closure 0.718  string 0.643
goto_warm: closure 1.007  string 1.027
click_force: closure 1.101  string 1.053
layout: closure 1.023  string 0.964
screenshot: closure 0.999  string 1.001
```

Drift between two reads of the SAME arm inside this run: `launch 93.664
vs 417.18`, `int_math 144.2 vs 159`, `js_alloc 56.6 vs 66.1`. Noise floor
≥10% on several rows against a claimed ≤3.6% string-code benefit means
the preload moves nothing measurable — `launch` itself is unusable in
this harness (drift >4x the row's own signal). Matches the first
retraction above: two closures of this experiment, two nulls.

The run initially came back red on `perf-report`, not on the numbers:
`jq`'s `EXPR as $x | body` requires a **Term** to the left of `as`, so
`(a+b) / 2 as $none | …` bound `$none` to `2` and divided the sum by the
pipeline's string instead. Fixed by parenthesising the whole division —
PR #309 — then verified by replaying the fixed jq against this run's own
artifact rather than redispatching.

2026-10-06 counted re-check (laptop, preload reaching chrome for the first
time — the shim's `unset LD_PRELOAD` had kept CANDIDATE_LD_PRELOAD out of chrome,
fixed by CHS_LD_PRELOAD in d0b0129): layout_text +10% instructions, wall 1.04x.
Still a loss with the byte tail; details in [[project_chromium_insn_mix_2026_10_06]]. Tail-fix rerun below.

2026-10-06 tail fix (c7a2508: <32 B copies/sets as two overlapping word
loads, ≥32 B finish with one 32 B store at n-32) — laptop rerun, i3-4005U,
one draw each, candidate vs promoted:
layout_text wall 1877 vs 1945 ms (0.97x), task-clock 0.91x (was 1.04x);
layout_reflow 465 vs 499 ms (0.93x); eval_rtt 508 vs 521 ms (0.97x);
click/screenshot/js_alloc 1.00x. layout_text musl 226 ms/iter → faststring
159 ms + musl 13 ms. FIRST time the shim reads as a win, but: one laptop
draw; promoted's own layout_text instructions/iter moved 5.65e3→6.39e3
(+13%) between the two runs of the same image (4 PMU counters, multiplexed),
so trust wall/task-clock, not instruction ratios. Not shipped; needs a CI
perf-gate draw (jean's dispatch call). Old-tail data:
laptop ~/ci-prebuilds/tmp/counted-chs-latest-oldtail/.

2026-10-06 night: gate can now preload into chromium (d2042c2: Dockerfile.alpine
ARG/ENV CHS_LD_PRELOAD, set via perf-gate candidate_build_args=
CHS_LD_PRELOAD=/usr/lib/libfaststring.so). Dispatched perf-gate 37524874478
(candidate vs promoted chs-latest = same image +/- faststring). RESULT (EPYC 7763, 5 shots, env lines verified:
candidate CHS_LD_PRELOAD=libfaststring.so vs promoted empty): PASS. Ratchet
(faststring vs none) geomean 0.988, layout 0.993, goto_warm 0.984, goto_cold
0.958 (cv 0.057), dom_churn 0.959, click_force 1.000, launch 0.987, rest 1.00.
Parity vs official geomean 0.994, layout 1.015, goto_warm 0.986, goto_cold
1.035. Read: a small win, mostly at noise level (one draw); no row
worse. Shipping (loading it by default) is jean's ruling.

2026-10-06 22:xxZ, 6 more draws of the same gate (37527624043..37527644796;
3x 9V74, 2x 7763, 1x 9V45, no Intel drawn). Faststring vs none (ratchet):
layout 0.954-0.999 in 7/7 draws (mean ~0.984), geomean 0.985-1.010 (mean
~0.997 = noise). Ours+faststring vs official geomean: 7763 0.994/0.999/0.998,
9V74 1.011/0.986/1.005, 9V45 1.010. 4/6 BREACHED parity on goto_cold
(1.09-1.12 on every 9V45/9V74 draw, 7763 1.03-1.06) and context_page (1.07,
1.11): NOT faststring, its ratchet goto_cold is 0.98-1.03; the plain image
already read goto_cold 1.072 on 9V45 (37469428206). Verdict: faststring =
small layout-only win; the cold-nav gap on Zen4 9V* is the real open row.

SHIPPED d577feb (2026-10-06 ~23:00 Paris): Dockerfile.alpine ARG
CHS_LD_PRELOAD default = /usr/lib/libfaststring.so; conformance build-runner.sh
(headless chromium) now builds it via run-gate.sh and wraps
chrome-headless-shell with the same CHS_LD_PRELOAD launcher. To price "none"
in perf-gate: candidate_build_args=CHS_LD_PRELOAD= . Validation: conformance
37531243080 (chs-latest, pw 1.62.1, rev 1234), TP 37531139881.
