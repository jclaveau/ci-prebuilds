---
name: project_tally_eta_format_and_chain_shape
description: "tally.py --format eta` (PR db3c394) gives a loop watcher machine-readable boundary_eta/chain_eta/pace/wakeup_delay per run, built after discovering the real chromium chain shape is r1-r6 full ~5.2h, r7 partial, r8-r12 link-only ~0.35h — the day-long ETA gap blamed on tally in [[project_tally_eta_and_filters]] was the watcher's own arithmetic, not tally's"
metadata:
  type: project
---

A `/loop` watcher had been hand-deriving chromium chain ETAs every tick by
multiplying the current round's mean duration by 12 rounds, and flagging
"tally's chromium ETA is off by a full day" against the FALLBACK_PROFILE
note in [[project_tally_eta_and_filters]]. Jean asked why the loop's own
`ScheduleWakeup` delay wasn't derived from the retrieved ETA, which forced a
real measurement before building anything.

**The retraction:** audited 6 completed chains before writing code. Real
shape is **r1-r6 full ~5.2h each, r7 partial (0.6-2.9h), r8-r12 link-only
~0.35h each, finalize ~0.75h — 34.6-37.5h total**, e.g.
`setup:0.44 r1:5.19 r2:5.20 r3:5.20 r4:5.17 r5:5.22 r6:5.18 r7:2.16
r8:0.36 r9:0.43 r10:0.35 r11:0.44 r12:0.35 finalize:0.76 = 36.5h`.
Multiplying 12 rounds at the full ~5.2h rate (what the watcher had been
doing by hand) overshoots by about a day. `round_profile()`'s own fallback
already had roughly the right shape — the "off by a day" flag repeated
every tick in the prior session was the watcher's arithmetic error, not a
tally bug. **[[project_tally_eta_and_filters]]'s closing paragraph, which
blamed this on the FALLBACK_PROFILE, is corrected by this memory — the
fallback shape was fine; what was missing was reach (see below).**

**What was genuinely wrong, and fixed in `scripts/tally.py`:**
- `round_profile()` only scanned the newest 60 runs; the last full chain
  was older than that window, so it read `fallback` anyway (separately from
  the arithmetic bug) and charged a full 5.2h for r7 instead of partial.
  Widened the scan to 200 runs — now lands a real chain's profile (e.g.
  `round profile from 31da628`) instead of `fallback`.
- Added `run_pace(stages, profile)`: duration-weighted own/profile ratio,
  so a chain's remaining stages are predicted at *its own* silicon's pace
  applied to the *profile's* shape (not a flat per-round multiply).
  Candidates read pace 1.006-1.011.
- Added `build_eta(jl, now, profile, durations)`: one normalizer used by
  both the human table and the new machine format, so they can't drift
  apart.
- Added `wakeup_delay(s) = clamp(60, 3600, s + 180)` — the 180s slack lands
  the next tick *past* the boundary so it reads a completed round, never a
  couple minutes short. This is now the single source for a loop's
  `ScheduleWakeup delaySeconds`, replacing hand-sizing (3600→2400→1200 by
  feel).
- New `--format eta`, one line per run plus a `next_boundary=... wakeup_delay=`
  summary line:
  ```
  run=35969194229 branch=perf/chromium-march-v3 sha=f13ab28 stage=chs-r5 elapsed=10087 pace=1.006 boundary_eta=2026-09-25T09:59:11Z chain_eta=2026-09-25T20:17:01Z
  next_boundary=2026-09-25T09:59:11Z run=35969194229 stage=chs-r5 wakeup_delay=3600
  ```
  Corrected chain ETAs came back **09-25 ~20:17/20:28/20:31Z** (same day),
  not the previously-reported 09-26 ~22:36-22:53Z.

**Tests:** tally had none before this. `tests/scripts/test-tally.py`, 39
checks, no network (`build_eta` takes a job list, never a run id) — covers
`chs_stage`, pace weighting and what doesn't count as a measurement, the r5
forecast against a hand-computed boundary/chain, an all-skipped
firefox-only dispatch, between-jobs/conformance-tail, plain-job prediction
plus past-its-longest, delay clamp at both ends, `remaining_seconds`. Wired
as `.github/workflows/tests-tally.yml` on `scripts/tally.py` +
`tests/scripts/**`. Mutation-tested 6/6 caught (one first-pass survivor —
"skipped stages counted" — the case was vacuous; replaced with a real one).

**Shipped straight to `main`** as `db3c394` (rebased over a concurrent
`ced3e58` tally change, retested 39/39 green after rebase) — see
[[feedback_merge_without_review_here]], extended 2026-09-25 to cover direct
commits, not only PR merges.

**How to apply:** a `/loop` watching chromium chains should call
`python3 scripts/tally.py --format eta` and read `boundary_eta` /
`chain_eta` / `wakeup_delay` verbatim — never hand-derive a chain ETA by
multiplying a round mean by rounds-remaining, the real shape is far from
uniform. Size `ScheduleWakeup delaySeconds` from that same `wakeup_delay=`
field.
