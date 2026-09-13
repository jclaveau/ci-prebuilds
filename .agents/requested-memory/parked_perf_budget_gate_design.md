---
name: parked_perf_budget_gate_design
description: SHIPPED 2026-09-09 (PR #195) — the perf gate is built and wired into promote; kept for the design rationale and the budget-sizing correction that followed
metadata:
  type: project
author: Jean Claveau
---

User asked: now that WebKit/Firefox are near-parity, should the perf bench
assert instead of just report? Proposed a three-tier design rather than a
naive `assert ratio <= 1.00` (which would flake hard — three concrete
reasons measured this session).

**Current state (verified, not assumed):** `perf-report.py` already computes
`RATIO_WARN = 1.30` / `DRIFT_WARN = 0.20` but only renders `⚠`/`🔺` emoji;
`main()` always exits 0, and if no probe results are found it prints a
message and still returns 0. The TP inline probe step is
`continue-on-error: true` and not in `promote`'s `needs`. Only
`assert-one-machine.py` (dispatch-only `perf-probe.yml`, n=5) actually
asserts anything today, and it only checks CPU-model consistency across arms
([[project_source_tag_probe_pattern]]).

**Why a flat `<= 1.00` gate is wrong:**
1. Parity isn't decidable at CI sample sizes — 10/13 firefox rows are
   statistical ties at n=10; gating a tied row is a coin flip.
2. The same binary crosses 1.00 by runner draw alone — WebKit `libm_fmod`
   reads 0.93 on an EPYC 7763 and 1.12-1.14 on a 9V74
   ([[project_wk_fastfmod_ships]]), so a flat threshold is really a CPU
   lottery gate.
3. Seeding budgets from *currently shipped* numbers would enshrine open bugs
   as the contract — WebKit `launch` read 1.40 in the seed run because #180
   hadn't shipped yet at capture time (now fixed, see
   [[project_wk_launch_is_the_loader]]).

**Proposed tiers, in payoff order:**
- **Tier 1 (do first, independent of any numbers):** fix the vacuity hole —
  `perf-report.py` must fail (not exit 0) on: no probe results, a missing
  expected (browser × target) cell, or a null/zero median/sample-count. Also
  drop `continue-on-error: true` on the TP probe step. This is the failure
  mode the repo actually keeps hitting (green proving nothing), and it's
  deterministic — no CPU/noise dependence.
- **Tier 2:** a committed `perf-budgets.json` keyed by (browser, row),
  seeded from the *proof images* (not shipped-at-seed-time), tight only on
  the rows proven pinned across CPUs (`locator_click`, `int_math` read
  1.00-1.01 across 3 browsers × 2 CPU models — near-zero flake budget there).
  A PR that regresses a row must edit the budget, surfacing the regression in
  review. Live in a new `assert-perf-budgets.py` rather than bolted onto
  `perf-report.py`, since that file takes `sys.argv[1]` with no guard today.
- **Tier 3:** keep `<= 1.00` parity tracking as a *report*, not a gate, in
  `perf-probe.yml` at n>=5 with explicit per-CPU expectations for the one row
  that needs them (`libm_fmod`).

**Sequencing note:** wire Tier 1+2 to fail the job but keep them OUT of
`promote`'s `needs` at first — visible and red on main without blocking
publish, until the budgets prove they don't flake over a few weeks of runs.
Seed Tier 2's numbers only after PR #192 (the WebKit retag) landed, so
`launch` seeds at ~0.87-0.88 rather than the pre-fix 1.40.

**Status: not started.** User has not said go. This is the full rationale so
it doesn't need re-deriving when they do.

---

## SHIPPED 2026-09-09 — PR #195, squash-merged

User gave the go ("let's add the assertions now 5% is not that bad", then
"wire it to the promote"). Built as designed:

- `playwright/bench/assert-perf-budgets.py` — structural check (control
  present per browser, one of our images beside it, every budgeted row
  present both sides, no zero/negative/NaN median) plus per-row budgets.
- `playwright/bench/perf-budgets.json` — per-(browser,row) ceilings.
- `test-and-publish.yml` — `continue-on-error` dropped from `perf-report`,
  and `perf-report` added to `promote`'s `needs`.

**The correction that mattered.** The first budgets were seeded from median
ratios and the gate immediately failed its own PR: `chromium/screenshot`
1.81x against a 1.75 budget, on a row whose median is 1.00. The gate takes
ONE shot per target, so it must be budgeted off the single-shot tail.
Re-seeded from 90 paired shots (perf-probe runs 34289013835 / 34289022039 /
34289030252) at the bootstrapped single-shot p99; six rows had been under
their tail. Verified by replaying all 90 shots (0 failures) and by mutating
a passing shot (int_math 5x, locator_click +50%, libm_fmod +30%, missing
row, zero median, empty metrics — all caught).

Generalised in [[feedback_threshold_from_tail_not_median]].

