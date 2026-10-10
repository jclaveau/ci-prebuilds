---
name: project_tally_candidates_percpu_aggregation
description: PR #303 extends tally.py's candidates table (perf-gate runs) with the same per-cpu geo / global geo / fleet geo / k-of-n-above-1.00 rows the shipped-browser table already had, so a chromium/firefox/webkit candidate with 2+ dispatched draws gets an aggregate verdict instead of reading each gate run's ❌/✅ as if it were the build
metadata:
  type: project
---

Follows directly from [[project_chromium_fortify_textstack_draw_lottery]]:
`assert-perf-gate.py` decides ship/no-ship off one draw, and `tally.py`'s
`candidates` section had no aggregation across draws of the same candidate
tag — one row per gate run, `cpu_short` printed but never binned, unlike the
`shipped` section which already did per-cpu/global/fleet geo. So there was no
one-command way to ask "what does this candidate read across its draws,"
and reading a single gate's ❌ as if it settled the build followed from that
gap, not from a considered choice.

**Shipped (`scripts/tally.py`, +35/−8, reporting only):** the candidates
table now groups gate runs by candidate tag and, from two draws up, prints
the same three rows the shipped table always had, through the same helper
functions — no duplicated aggregation logic:

```
per-cpu geo (n=…)                      <model>
global geo (n=… draws, as drawn)       all
fleet geo (per-cpu geo x fleet share)  all
```

plus the `k/n above 1.00` sign-test counts the shipped table already
carries — the thing a single draw cannot produce at all. Verified
byte-correct against the real cache: `above` counts carry through as
`(1, 2)`, and fleet weighting pulled the fortify candidate's nav row from
1.009 (as-drawn) to 1.042 (fleet-weighted) because EPYC 7763 is 59% of the
fleet and 9V45 only 6% — the aggregation isn't cosmetic, it changes which
number is the one to act on.

Nothing touched in `assert-perf-gate.py`, the margins, or any promote path —
the gate still decides off one run; whether it should require multi-draw
agreement before a promote is a gate-policy change, jean's call, not
addressed by this PR.

**How to apply:** once a chromium/firefox/webkit candidate has 2+ dispatched
(not rerun — see [[project_chromium_fortify_textstack_draw_lottery]]) gate
draws, read its per-cpu/global/fleet geo from `tally.py perf` before ranking
it against another candidate or calling a row's breach real. One gate run's
❌/✅ alone is not evidence about the build, only about that draw.
