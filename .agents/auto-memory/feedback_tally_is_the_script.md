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
workflow and ~60 lines of output. He asked for exactly this (2026-09-15).

**How to apply:**
- Ratios in the script are OURS/OFFICIAL (the goal is every row ≤ 1.00);
  chs-perf-ab and the perf-report print the inverse — say which when quoting.
- ETA = the round profile of the newest completed chain applied to the stages
  left; ±1 h. `~` on a group = every row inside its own sample spread.
- `--depth 300` once per machine seeds the conformance cache (webkit's
  suite only runs when webkit is rebuilt, weeks apart).
- A build-progress question mid-chain is `pnpm tally builds`, nothing else.
