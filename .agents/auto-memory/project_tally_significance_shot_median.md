---
name: project_tally_significance_shot_median
description: tally.py's `~` noise flag pooled every raw iteration across shots and tested |Δmedian| against the raw range — range only WIDENS with more shots, so going 1→3 shots made `~` fire MORE often, backwards from the intent; fixed in PR #294 to use shot-median spread when both sides have ≥2 shots
metadata:
  type: project
---

**Found 2026-09-22, day after PR #291 shipped the 1→3 shot bump.** jean asked
"n=3 still produce ~ numbers?" — yes, and it's a rule flaw, not real noise.

`significant()` was pooling every raw iteration from every shot into one
distribution per side, then testing `|Δmedian| ≥ full raw range`. Raw range is
governed by the noisiest single iteration, which only grows as more shots
(hence more iterations) are added — so raising shot count made the flag
*more* likely to fire, the opposite of the intended effect.

Example (chromium 67b23c8, EPYC):

| metric | ratio | raw-range | shot-median-range | shot medians ours / official |
|---|---|---|---|---|
| goto_warm | 1.055 | 24.5 | 6.6 | [218,217,223] / [207,207,205] |
| eval_rtt | 1.091 | 128.5 | 27.4 | [270,290,297] / [266,263,268] |

goto_warm: all 3 ours-medians sit above all 3 official-medians — real signal —
but was flagged `~` because raw range (24.5) swamped the delta.

**Fix (`scripts/tally.py` only, PR #294):** `load_cells` now keeps per-shot
medians; `significant()` uses the shot-median spread instead of the raw range
whenever both sides have ≥2 shots (raw range stays as the n=1 fallback).

**Why shot medians, not raw iterations, are the right unit — worked out with
jean before writing the fix:** iterations inside one shot share process
state, so they are not independent draws; shots are. With 3 vs 3 shots, "all
ours above all official" is the strongest separation Mann-Whitney can show:
U=0, p=1/20 one-sided. So even after the fix, `~` at n=3 means "not
separable at p≈0.05" — a usable flag, weak as proof. n=5 would reach p=1/252
but costs ~+4 min per perf job; **decision: skip raising shot count for now,
revisit only if sign counts stay ambiguous.**

**Where the real statistical power already lives: across runs, not within
one.** Draws on different CI runs/runners are independent, and tally already
geomeans rows across shipped runs without counting the sign — chromium nav
sat >1.00 on 6/6 shipped draws (sign-test p=1/64), a far stronger signal than
any single row's shot spread. Proposed second step (not yet built): show the
sign count alongside each aggregate row, e.g. `nav 1.03 (6/6>1)`, so the
per-CPU/global rollup lines carry the significance evidence instead of the
single-run `~` flag.

**State after the fix, same draw (67b23c8):** chromium fleet geo 1.02 (nav
still the residual gap at ~1.03-1.06); firefox fleet geo 0.93 (geo 0.95);
webkit fleet geo 0.88 (geo 0.87), input now ~0.99 (was 1.04 on an earlier
candidate row — the 1.04 was that row's own noise, not a regression).

Complements [[feedback_tally_is_the_script]] (what the script does and how to
read it) — this memory is about a bug in its significance math and the
statistical reasoning behind the fix.
