---
name: feedback_tally_is_the_script
description: "tally" / "builds tally" / "perf tally" = run `pnpm tally` (scripts/tally.py) and relay its output — never hand-assemble the tally from gh calls; jean asked for the script to cut the tokens the tally used to cost
metadata:
  type: feedback
---

When jean asks for a **tally** (builds, conformance, perf, or all three), run
`pnpm tally` (`python3 scripts/tally.py [builds|conformance|perf]`) and relay
the lines — one section when he names one, everything otherwise. Add only
what the script cannot know (what a number means for the next step).

**Why:** the tally was assembled by hand from `gh run view` / job logs /
artifact downloads several times a day, at thousands of tokens each. The
script caches every completed run's jobs and perf artifacts under
`~/.cache/ci-prebuilds-tally`, so a repeat call is one `gh run list` per
workflow and ~60 lines of output. He asked for exactly this (2026-09-15),
shipped as PR #247/#248.

**How to apply:**
- Ratios in the script are OURS/OFFICIAL (the goal is every row ≤ 1.00);
  chs-perf-ab and the perf-report print the inverse — say which when quoting.
- ETA = the round profile of the newest completed chain applied to the stages
  left; ±1 h. `~` on a group = the shot medians of the two sides overlap
  (n≥2; U=0 at 3 vs 3 is only p=1/20, so a single row's `~` is weak either
  way). The `k/n` on aggregate rows is the sign test across draws — the
  significance carrier: 6/6 or 0/6 is p=1/32. Never pool raw iterations
  across shots for a spread: it only widens with n (the pre-2026-09-22 bug).
- `--depth 300` once per machine seeds the conformance cache (webkit's
  suite only runs when webkit is rebuilt, weeks apart).
- A build-progress question mid-chain is `pnpm tally builds`, nothing else.

**Since PR #291 (2026-09-21), `tally perf` shows all three browsers, not just
chromium:**
- firefox / webkit / chromium each get a **candidates vs official** table
  pulled from every perf-gate artifact (manual dispatches + the
  `perf-gate-<browser>` jobs baked into the build workflow), with the
  promoted `<browser>-latest` build's own ratio printed as a reference line
  under each candidate row (same runner as the candidate, so it's a fair
  same-draw comparison). `chs-perf-ab`'s A/B table is kept only as a legacy
  path.
- `n` = probe-shot count behind the row; **TP perf-probe and chs-perf-ab both
  went 1→3 shots** (chs-perf-ab via a `runs` input, default 3) specifically
  so single-shot `~` noise stops showing up — perf-gate was already 5.
- New `fleet geo` row + a GHA runner-mix line at the bottom
  (`EPYC 7763 57%, 9V74 17%, 8573C 9%, 8370C 6%, 9V45 6%, 6973P 4%`, from
  117 cached jobs). **`global geo` is runner-weighted by whichever CPUs the
  sampled draws happened to land on, NOT by fleet share** — it can diverge
  from `fleet geo` (per-CPU geo × fleet share) by several points. Quote
  `fleet geo` when the question is "how much does this matter in prod",
  `global geo` when it's "did this specific chain regress".
- "Shipped" table header is now `main sha  date  run` — those rows are ALL
  the same consumer image (Dockerfile.alpine pins exact chs/ff/wk revs),
  redrawn on whatever runner GH handed out; the hash is which main commit TP
  built from, not a browser build id. Don't read row-to-row spread there as
  a browser regression signal — it's runner variance.

Complements [[feedback_tally_include_run_url]] (the run URL the script itself
cannot append) — this memory is about WHICH tool to run, that one is about
what to append when relaying it.
