---
name: project_perf_record_report_whole_run_normalisation
description: perf-record-report.py divides perf-stat counts by the WHOLE-RUN iteration rate (kernel.json), not the stat pass's own bracket (windows.txt `stat`); the loop rate differs pass to pass (strace/callers slow it unevenly), so its "instructions / iter" can read 1.35x on a byte-level no-op; recompute from the bracket before trusting a counter ratio
metadata:
  type: project
---

`perf-record-report.py` `counter_rates()` turns each `perf stat` block into
count/second, then divides by `iter = kernel.json iterations / seconds` —
the average over the whole 200 s loop. The stat block only covers the
`stat` pass, and the loop runs at a different rate in each pass (ptrace
under strace, fp unwinding under callers), unequally per arm.

**Evidence (2026-09-27, local i5-8350U, old B 7c4e2ab vs c64d783,
libxul SIMD byte-identical = a no-op build):**

| kernel | report | bracket-normalised |
|---|---|---|
| screenshot_png_text | 1.35x | 0.997 |
| layout_reflow | 0.85x | 0.972 |
| js_alloc | 0.98x | 0.981 |

Bracket-normalised = `instructions (20 s HW block) / (end-start of the
windows.txt "stat" line)`, same for both arms. On the c64d783-vs-promoted
run both methods agreed (screenshot 1.15/1.154), so the error is draw-
dependent, not a constant bias.

**Why:** a counted compare exists to be the runner-independent second
opinion; a normaliser that swings ±35% on a no-op defeats it.

**How to apply:** until the report is fixed, recompute any counter ratio
from `<arm>-<kernel>-stat.txt` + `-windows.txt` before quoting it. Fix
(unshipped, needs jean's go): divide stat counts by `windows()['stat']`
iterations over the bracket seconds, not `rates['iter']`. Blocks sum to
50 s inside a 45 s bracket (`STAT_WINDOW + 25`, perf-profile.sh:259) —
widen the bracket too. Related [[project_ff_pgo_extended_corpus_jetstream_motionmark]].
