---
name: project_chromium_insn_mix_2026_10_06
description: per-instruction mix, ours chs (consumer 0929, mimalloc-secure) vs PW 1.62.1 official on jean's i5-8350U — chrome binary retires FEWER instructions on 6/8 kernels; excess is musl memset (rep stosq)/memcpy/printf_core and the node driver; losing rows are eval_rtt 1.08x and locator_click 1.07x cycles, driver-side
metadata:
  type: project
---

Tool: `playwright/bench/perf-insn-mix.py` (45c239d; `uv run --script`, capstone pinned inline), fed by
`PERF_KEEP_INSN_DATA=1 local-counted-compare.sh chromium official <img>` (keeps
`<arm>-<kernel>-insn.data`). Our function names come from the chain's
`chromium-link-census` symtab (`tmp/census-ccc8534/`); official is unnamed.
Full output `tmp/insn-mix/insn-mix-all.md`.

cycles/iter ours vs official (frequency-free; task-clock drifts with laptop turbo,
do not read it): eval_rtt 929 vs 862 (1.08x), locator_click 4200 vs 3920 (1.07x),
goto_cold 1.01x, goto_warm 1.00x, screenshot 1.00x, js_alloc 0.93x, layout_text
0.92x, layout_reflow 0.85x.

- chrome binary (+harfbuzz, separate DSO in ours) retires fewer insn on every
  kernel but js_alloc (+1%) and eval_rtt (+2%). goto: insn 0.95x but IPC 0.95x,
  L1i +9%, branch miss +6-9% = code layout, see [[project_chromium_layout_gap_is_frontend_fetch]].
- Hardening is NOT an excess: trap guards ud1 0.79x, CFI rotate idiom 0.37x of official.
- musl excess: `memset` (asm, size 0 in dynsym: nm shows it as "static after
  wcswcs") is 193 M/iter in layout_text, 107 M of it `rep stosq` (musl uses rep
  stosq above 126 B; glibc uses vector stores below its rep threshold);
  `memcpy` 46 M in locator_click; static `printf_core` (gap after `gets`) 1.2 M in
  goto_warm. Prior A/B: [[project_chromium_faststring_moves_layout_text]] (wall-time
  noise killed it; never re-run on cycles).
- node driver: same v24.18.1, ours Alpine (lto, shared openssl), official static.
  `node JIT` 1.9-2.6x ours, `node` C++ 0.8x; net node+JIT +3% eval_rtt, +5% click;
  mimalloc-secure +22 M eval_rtt, +64 M click (official malloc sits in libc);
  8448ca5 already moved the preload to insecure.
Parked by jean 2026-10-06: the faststring counted A/B (CANDIDATE_LD_PRELOAD=/usr/lib/libfaststring.so, ~70 min local, quiet box) waits until jean frees the PC; ask before starting.

CI follow-ups dispatched 2026-10-06 (jean "go both"): perf-gate 37469177628
(main 45c239d, chs-latest vs chs-latest = image with 8448ca5's insecure driver
preload; read eval_rtt/locator_click vs official) and perf-gate 37469428206
(0a5c200, candidate == promoted == chs-fs-sha-ccc8534, candidate_build_args swaps
/usr/bin/node for nodejs.org's musl 24.18.1 tarball; the candidate/promoted
ratio prices the node swap alone). Parity reds on those runs are informational.

RESULTS 2026-10-06:
- perf-gate 37469177628 (chs-latest, insecure-mimalloc driver): parity
  eval_rtt 1.001, locator_click 1.000 — both at the bar on CI wall time;
  the 1.07-1.08x cycle excess does not show as wall. Red = goto_cold 1.076,
  layout 1.037 parity; context_page 1.062 ratchet (candidate == promoted, so noise).
- perf-gate 37469428206 (static musl node 24.18.1, `shared_openssl=false`
  confirmed in the stage log): ratchet eval_rtt 1.026, click_force 1.067 ❌,
  geo 1.008. The node swap buys nothing on wall: DEAD, keep the opt-in arg unused.
- Faststring counted A/B on the famille laptop (i3-4005U, chromium-only
  preload via CANDIDATE_CHROMIUM_LD_PRELOAD, d0b0129): layout_text instructions
  1.10x, wall 1.04x, task-clock 1.04x (the byte-at-a-time tail); layout_reflow
  wall 0.96x; eval_rtt/click/js_alloc/screenshot 1.00x wall. Cycles read
  0.89-0.94x where task-clock reads 1.04-1.09x: on Haswell's 4 counters the
  event list multiplexes, and this CPU has no turbo, so trust task-clock there.
  Faststring stays unloaded. See [[project_chromium_faststring_moves_layout_text]].
