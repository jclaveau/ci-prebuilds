---
name: project-chromium-residual-tracks-2026-10-08-counted
description: 2026-10-08 laptop (i5-8350U) counted — goto_cold ours does LESS work than official (insn 0.95x), CI residual is waiting; layout_reflow "+94 M insn from textstack" RETRACTED — same-session A/B textstack vs old build reads insn 0.98x, cycles 0.96x; our layout_reflow insn/iter swings 1146-1252 M between sessions (official stable), laptop CPU-ms is frequency-confounded
metadata:
  type: project
---

Run: `PERF_KERNELS=layout_reflow,layout_text,goto_cold local-counted-compare.sh chromium official jclaveau/alpine-dood-playwright:latest`.
- Image: Docker Hub :latest, revision dd00279, built 01:58Z. Its chromium has NEEDED fontconfig, with no freetype or harfbuzz, so it is textstack.
- Output: tmp/counted-official-chromium/report.md.
- Previous run (pre-textstack, and pre-faststring-preload too, since there is no libfaststring DSO): tmp/counted-official-chromium.pre-textstack/.

| kernel | counter | ours now | ours pre | official now / pre |
|---|---|---|---|---|
| goto_cold | insn/iter | 356 M (0.95x) | 359 M (0.97x) | 376 / 372 M |
| goto_cold | cycles/iter | 403 M (1.01x) | 408 M (1.01x) | 399 / 403 M |
| layout_reflow | insn/iter | 1290 M (1.05x) | 1190 M (0.97x) | 1230 / 1230 M |
| layout_reflow | cycles/iter | 772 M (1.08x) | 646 M (0.85x) | 716 / 758 M |
| layout_reflow | wall | 1.09x | 1.02x | |

- **goto_cold:** ours retires fewer instructions than official. The CI residual (1.024 median at runs=10) is not work, which fits "goto_cold = waiting" in [[project_chromium_residual_tracks_2026_10_07]].
- **layout_reflow:**
  - Inside chrome-headless-shell.real, ours went from 1158 to 1252 M insn/iter (+94 M, +8%), while official's binary moved only from 1192 to 1200 M.
  - No harfbuzz or freetype DSO shows in either alpine split. faststring nets about +1 M (+18.9 M in libfaststring, −16 M in musl).
  - So the extra instructions sit in OUR binary. Suspects: the textstack build, i.e. a different chain or PGO profile vs ccc8534, or text code now inlined in-binary.
  - Same direction as the dom_churn A/B, insn 1.06x textstack vs old. That was earlier dismissed as sampling noise plus GC, which is now doubtful.
- **layout_text:** void, because the checksum differs between arms (font mismatch, [[project_probe_font_mismatch_confounds_layout]]). Its counters read parity anyway.
- **CI:** 10-shot parity layout median is about 1.006 and the promote ratchet layout was 1.02, so the effect is small on EPYC. Unknown on Intel CI.
- **Next, not run yet:** a symbol-level instruction diff of layout_reflow, textstack vs the old shipped build.
  - Needs the census artifacts re-downloaded: build runs 35645764121 (textstack) and 35291178853 (ccc8534).
  - Needs the old build as promoted, rollback digest sha256:7ecdcdef754675dda6ac5b9da5dd6d7ee45fc43c57d2b159c0f03b4e491a6e70.
  - Run with PERF_KEEP_INSN_DATA=1.
- **Report quirk:** "arms are on DIFFERENT chromium versions" is a false alarm, since both are 151.0.7922.34 and only the product name differs.

## RESOLVED 11:08Z: textstack does not add layout_reflow work
Same-session A/B, both images staged like perf-gate (faststring on both):
`PERF_KEEP_INSN_DATA=1 PERF_KERNELS=layout_reflow local-counted-compare.sh chromium chs-fs-sha-6e56156… 1234 chs-fs-sha-ccc8534…`. Started after jean stopped zen; output in tmp/counted-chs-fs-sha-6e56156…/.
- Totals, textstack vs old: insn 1180 vs 1210 M (0.98x), cycles 680 vs 710 M (0.96x), IPC 1.03x. In the chrome binary: 1145.8 vs 1170.8 M.
- BUT CPU-ms is 1.11x, task-clock 1.10x and wall 1.07x. Cycles went down while task-clock went up, so the candidate ran at a lower clock. Laptop wall and CPU-ms are confounded by turbo and thermals: trust cycles and instructions.
- Our binary's layout_reflow insn/iter across runs: 1158 (10-07, official mode), 1252 (10-08 09:41Z, official mode, zen running, load ~4), 1146 and 1171 (11:08Z, quiet). Official's: 1192 and 1200.
- So the +94 M was run-to-run variance of OUR arm, not the build. GUESS: contention raises per-iteration work, e.g. more frames or polling. Untested.
- The function-level diff was not run; at 0.98x there is nothing to localize.
- Lesson: compare counts only within one session, and with the box quiet.
