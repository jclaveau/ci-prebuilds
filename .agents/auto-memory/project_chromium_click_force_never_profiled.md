---
name: project_chromium_click_force_never_profiled
description: PROFILED 2026-09-23 (run 35869661523) — nav (goto_warm) and input (click_force) both isolate to musl's scalar memset/memcpy vs glibc AVX2, +1.55pp and +0.76pp; kernel/browser-text/node otherwise match within ±0.1pp on both arms; PMU still refused a 3rd time (cpu-clock sampling used instead); callers unattributable (both binaries stripped), click_force is 21-29% node/CDP on both arms
metadata:
  type: project
---

**RESOLVED 2026-09-23, run `35869661523`** (dispatched on jean's go, both
arms, `cpu-clock` sampling — PMU refused a third straight time,
`cycles`/`instructions` `<not supported>` on both). Same 5s system-wide
window on both arms (nav 66K vs 67K samples, input 43K vs 42K), so shares
are directly differenceable without normalizing.

**`nav` (`goto_warm`) — everything matches except musl's string ops:**

| symbol | alpine | official |
|---|---|---|
| `memset` | **2.48%** (musl scalar) | 1.36% (`__memset_avx2_unaligned_erms`) |
| `memcpy`/`memmove` | **1.03%** (musl) | 0.60% (`__memmove_avx_unaligned_erms`) |
| `memcmp` | 0.19% | 0.17% (`__memcmp_avx2_movbe`) |
| `strlen` | 0.23% | 0.16% (`__strlen_avx2`) |
| kernel total | 33.23% | 34.81% |
| node | 3.21% | 5.16% |
| browser binary | 50.69% + 2.78% libharfbuzz = **53.47%** | 53.78% (harfbuzz bundled) |

Every kernel symbol within ±0.1pp, hot browser addresses match offset-for-
offset, alpine is *lower* on kernel and node. The only excess: musl
`memset`+`memcpy`, **+1.55pp — 1.8x and 1.7x the glibc AVX2 versions.**

**`click_force` — same shape, smaller:** musl `memcpy 1.30 + memset 0.77 +
memcmp 0.31 = 2.38%` vs glibc `1.62%`, **+0.76pp**.

**Two caveats before this becomes a lever:**
1. **Callers are unattributable** — both binaries are stripped, call graphs
   are raw addresses. This says *how much* musl memset costs, not *who*
   calls it.
2. `click_force` is **21–29% node** in both arms (CDP round trip) — the
   `input` row measures the driver/IPC as much as the browser, and the two
   images ship different node builds, so part of this row isn't ours to fix.

This is the first direct evidence behind the retracted AVX2-string-shim
episode ([[project_chromium_faststring_moves_layout_text]]) — that
retraction was "measured on the wrong artifact," never "the shim doesn't
help." Musl's scalar memset is now the single largest measured non-kernel
alpine excess on both residual rows. Follow-up: the shipped-but-disabled
`libfaststring.so` shim is being repurposed via PR #306 to A/B exactly
these two rows — see [[project_chromium_faststring_moves_layout_text]] for
the three-arm design (`none`/`loaded-off`/`loaded-on`) that separates the
DSO-closure cost from the string-code effect.

**Everything below is the pre-profile inventory that motivated the
dispatch — kept for the instrument catalogue, superseded by the results
above for `click_force`'s "never profiled" status.**

2026-09-23, jean asked to dig the `nav` and `input` residual rows. Inventory of
what's already measured, so the next probe isn't a repeat.

**`nav` (`goto_cold` + `goto_warm`) — rich, 4 instruments on record:**

| instrument | run | reads |
|---|---|---|
| 18-draw ratio sample, 4 CPUs | `sample-cpu-models.sh` | `goto_cold` 1.08–1.13, `goto_warm` 1.08–1.10 — 18/18 draws, every silicon |
| 7-pass perf-record (DSO/thread/symbol + sched + strace) | `35590487107`, 8573C | `goto_warm` 1.07 wall / 1.04 CPU, renderer main thread ONLY; DSO shares match to 1% except system `libharfbuzz` (1.7 ms/iter) + `libfontconfig` — see [[project_chromium_residual_gap_candidates]]'s 2026-09-21 entry |
| CDP trace | same + `35297557147` | `InlineNode::ShapeTextIncludingFirstLine` the only Blink phase slower in absolute ms (1.14x) |
| PMU counter table (PR #268) | dev-box i5 only | +50% instructions, IPC 1.19x, **better** L1i/iTLB/L1d per instruction — not code-layout |
| gate draws n=4 | fortify/textstack | `nav` 1.04, 4/4 and 3/4 breached — see [[project_chromium_fortify_textstack_draw_lottery]] |

**Hole:** the "+50% instructions" finding only ever landed on a laptop i5. The
one CI attempt at a PMU read, run `35496062522`, drew a PMU-less runner (alpine
arm: `No supported events found`; official arm: `<not supported>`). Its walls
survive (`goto_warm` 1.125, `goto_cold` 1.066) but predate PR #273 and carry no
sched/strace pass. Worth **redrawing**, not mining further — PMU access on
Azure/GHA runners is a lottery, plan 2-3 draws.

**`input` (`click_force`) — ratios only, never profiled:**

- 18/18 draws read 1.02–1.06. `locator_click` (same clicks) sits at parity —
  it's frame-cadence bound by design ([[project_runtime_perf_probe]]), so a
  `click_force` delta that also moves `locator_click` would be cadence, not CPU.
- CDP trace shares only: `RunTask` 27.0/26.3, `mojo` 15.8/17.6 (**ours faster**),
  `DisplayItemList::Raster` 1.86–1.95x (the one trace-wide outlier,
  [[project_chromium_trace_gap_is_uniform]]).
- **Never perf-recorded.** `browser-perf-record.yml`'s kernel exists
  (`perf-kernel.cjs:426`) and even defaults to it, but that workflow's
  `choice:` input is `[webkit, firefox]` only. Chromium's perf-record arm is
  `chromium-gap-probes.yml`, whose `perf_kernels` default is
  `screenshot_png_text,screenshot_png,screenshot_jpeg,layout_boxonly,layout_reflow`
  — `click_force` has never appeared in a dispatch.
- Two cautions before chasing it: `click_force`'s null-pair resolution floor is
  **0.07** ([[project_perf_probe_resolution_floor]]), bigger than the 0.02–0.06
  residual — only readable because gate arms share one job and 18/18 agree in
  sign. And webkit's identical 1.15 `click_force` turned out to be the **node
  driver's** mallocng, fixed container-wide by mimalloc
  ([[project_wk_input_gap_not_node_allocator]]) — chromium's wrapper `unset`s
  `LD_PRELOAD` for the browser but node keeps it
  ([[project_chromium_wrapper_unsets_ld_preload]]), so the driver half of this
  row is already paid regardless of what the browser-side profile finds.

**Probe that was dispatched (2026-09-23, jean said "go"), run
`35869661523`, 29 min:**

```
gh workflow run chromium-gap-probes.yml --ref main \
  -f run_static_probes=false -f run_perf_record=true \
  -f perf_kernels=goto_warm,click_force,locator_click \
  -f perf_loop_seconds=200
```

One dispatch covered both rows on the current consumer; `locator_click` rode
along as the in-kernel cadence control.
