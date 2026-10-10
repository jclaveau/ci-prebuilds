---
name: project_tally_eta_and_filters
description: tally.py grew a --run/--draws/--browser filter set (PR #300) and a measured firefox/webkit ETA (PR #301) after two gaps surfaced — dead build chains were invisible between two "tally" prompts (PR #299), and build-firefox's duration is bimodal so a median predicts 4 minutes for a 3h cold build
metadata:
  type: project
---

Three small PRs (#299, #300, #301) in one session, each triggered by a
concrete gap jean or the watcher hit, not a speculative cleanup.

**#299 — dead chains were invisible.** `section_builds` only listed
`status != "completed"` runs, so any firefox chain that failed *between* two
`tally` prompts left no trace — three FF PGO failures in one night vanished
this way until jean said "no wip ff build in the tally". Fixed with
`recent_failures()`: chains with `conclusion in (failure, timed_out)` and
`now - updatedAt < 24h` now get a row (`FAILED: <job1>, <job2>, …`). Fixing
it surfaced two more bugs in the same code path: a firefox-only dispatch
still carries every chromium job as `skipped`, and counting those as a chain
reported `chs between jobs 0/14` for a run with no chromium in it at all;
and the "currently running job" column showed conformance shards instead of
the actual `build-*` job. Both fixed in the same PR.

**#300 — "tally" is 92% perf output.** Measured before proposing anything:
`tally builds` is 6 lines / 621 B (~170 tok), `tally perf` is 54 lines /
7358 B (~2000 tok). Where perf's lines go: 3 shipped-browser blocks (1
header + 4 per-draw + 4-6 aggregate rows each) = 30, ff/wk candidates = 6,
chromium A/B pairs back to 09-15 = 12, fleet-mix + legend = 6. **Key fact
that makes a listing cap free**: `section_perf` computes per-cpu / global /
fleet geo over the FULL cached draw set regardless of how many per-draw rows
are printed — `rows[:draws]` only slices the listing, not the aggregate.
Added `--draws N` (default 1, was hardcoded 4) and `--browser <name>`
(repeatable via comma, for a loop tick that only cares about chromium during
the campaign — NOT the default, since parity is a hard-fail on all three
browsers). Dropped `--ab` default 12→4 (drops superseded arms: orderfile,
flags, cfi/shipped). Proof nothing was lost: `--draws 4 --ab 12` is
byte-identical to the pre-change output, and the per-cpu/global/fleet geo
rows are byte-identical at the new default — no tests exist for tally.py, so
this diff *is* the regression check. Deliberately did NOT add a filter for
the per-cpu geo rows: parity is CPU-dependent, which is the entire reason
`fleet geo` exists, so collapsing them would hide the one axis that flips a
verdict.

**#301 — build-firefox duration is bimodal, not normal.** Measured over 57
completed runs before designing anything: `[0.03, 0.03, 0.04, 0.04, 0.04,
0.04, 0.07, 2.80]` hours. A warm relink off the BuildKit cache mount is 2-4
minutes; a cold compile (forced by `patchset-hash.sh` reseeding the base
image) is 2h48. **No job field exposes which one a run will be** — a median
over past successes would predict ~4 minutes for a build that's actually
going to take 3 hours. The rule that works: **the shortest past success
still ahead of the elapsed time** (`remaining_seconds()` in
`scripts/tally.py`) — starts on the warm cluster, steps up to the cold one
the instant the relink window closes, self-correcting, no hash needed. Once
elapsed passes every recorded success it returns `None`, reported as `past
2h48, its longest success` — which is exactly the state every failed FF
build reached (2h55, 3h10) before dying, so the "off the map" case reads as
the interesting signal it is rather than a bogus number. Chromium keeps its
existing `chs_stage`/`round_profile` machinery (unaffected); this rule only
covers browsers with no stage breakdown.

**Also added:** `--run <id>` on `builds` prints one bare row (no header, no
PRs, no trailing URL) — built for a watcher to `tally.py --run <id>` every
poll instead of hand-rolling `gh api .../jobs` + jq, so the ETA a human reads
and the ETA a script polls come from the same code.

**How to apply:** before adding a new tally flag or column, measure current
output size/shape first (byte counts, not guesses) — twice this round a
"proposal" turned out wrong on contact with real numbers (a median ETA, and
an assumption that per-draw rows fed the aggregates). `job_durations()`
must scan every completed run in the depth window, not a fixed slice — a
20-run slice held exactly one warm FF success and zero cold ones, so the ETA
column came back empty; firefox/webkit dispatches are rare next to chromium
chains.

**Chromium's `round_profile()` (scripts/tally.py:163) falls back to
`FALLBACK_PROFILE` (~2h/round) when the branch has no completed-round
history of its own** — a brand-new candidate branch's first several `tally`
calls report an ETA off by a full day. Confirmed 2026-09-24/25 on three
fresh chromium candidates (march-v3, cfi-icall-off, libcxx-fast).

**RETRACTED 2026-09-25 — the "off by a day" verdict was wrong.** The gap
was a `/loop` watcher hand-multiplying a round's mean duration by all 12
rounds remaining, not a tally bug: the real chain shape is r1-r6 full
~5.2h, r7 partial, r8-r12 link-only ~0.35h (34.6-37.5h total, far from
uniform), and tally's fallback profile already had roughly the right
shape. The one genuine bug was scan depth — `round_profile()` searched only
60 runs, missing the newest full chain — fixed by widening to 200 runs.
Full writeup, the corrected chain-shape numbers, and the new
`--format eta`/`wakeup_delay` machinery: [[project_tally_eta_format_and_chain_shape]].
**How to apply:** don't hand-derive a chromium chain ETA from a round mean
— call `tally.py --format eta` and read `chain_eta` verbatim.
