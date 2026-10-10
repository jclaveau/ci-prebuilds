---
name: project_renovate_schedule_starved_majors
description: a 1x/week UTC schedule + prHourlyLimit 2 meant minor/patch PRs always ate the window and majors (checkout v7, node 24, ubuntu 26...) never got opened
metadata:
  type: project
---

Six majors were stuck in Renovate's "Awaiting Schedule" state (actions/checkout
v7, metadata-action v6, setup-buildx v4, upload/download-artifact major, node
24, ubuntu 26 — 26.04 LTS passes the even-year regex). Cause: `renovate.json`'s
`schedule: ["before 6am on Monday"]` is UTC, giving one 6h window/week;
`prHourlyLimit: 2` inside that window let minor/patch bumps ([[project_renovate_topology]])
consume both slots every Monday before majors got a turn, and
`prConcurrentLimit: 5` with 3 zombie PRs open (#234/#236/#237 — see
[[project_renovate_reappearing_pin_kills_automerge]] for two of those three)
left only 2 free slots anyway.

Jean's ruling (2026-09-21): **"go update renovate.json"** on the proposed fix,
shipped PR #286:
- `schedule: ["before 6am every weekday"]` (was Monday-only), `timezone:
  "Europe/Paris"`.
- `prHourlyLimit: 0` — the schedule window is the throttle now, the hourly cap
  was redundant with it and the actual bottleneck.
- New `packageRules` entry: `matchUpdateTypes: ["major"]` → `automerge: false`
  — majors open a PR but wait for a human merge (node 24 / ubuntu 26.04 are
  the ones this unblocks); non-major keeps automerge (already proven safe by
  #269-271 merging same-day).

Cost accepted: daily 6h window × up to 5 concurrent PRs, each triggering a
full test-and-publish (~1h+ CI) — fine on a public repo's free Actions
minutes, would not be fine on a paid runner.

**Superseded 2026-09-21, one day later**: the `automerge: false` for majors
line above (PR #286) was dropped again the same week — see
[[project_renovate_topology]] for jean's final ruling ("automerge in any
case"): TP build-tests + conformance already gate every automerge regardless
of category, so a green-CI major is already vetted, and majors had
automerged safely before (#235 pnpm v12) without this rule. The
schedule/timezone/`prHourlyLimit: 0` fix above is still live; only the
per-major-automerge-off packageRule reverted.

**How to apply:** if a renovate major sits in "Awaiting Schedule" again, check
this schedule/limit shape before assuming it's a new automerge-disable
sentence — the two causes look similar (PR never appears / never merges) but
have different fixes. Do NOT re-propose a majors-specific automerge:false —
that door is closed, see [[project_renovate_topology]].
