---
name: project_perf_gate_ratchet_and_parity
description: PR #288 adds a promote-time perf-gate job, hard-failing on BOTH ratchet (candidate/promoted) and parity (candidate/official) for all three browsers, chromium included
metadata:
  type: project
---

Jean ruled (2026-09-21) two things that didn't exist before: "better than parity
should be a threshold, but new promoted builds should never be slower than
previous ones," then, when asked whether chromium parity should be warn-only
given it's still red on nav/layout, **"make all parity check error chr also, we
wont stop until our build is better than parity."**

Consequence stated and accepted: `chs-latest` now freezes at today's build
until chromium reads ≤1.00 on every row — an improving-but-still-1.06 nav
build still can't promote. This supersedes the earlier idea (same session,
before the ruling) of warn-only parity for chromium, and is a harder line
than the existing TP regression alarm ([[parked_perf_budget_gate_design]]),
which only catches catastrophes on dispersion-bound rows and runs on the
*consumer* image after promote, not before it.

**Design shipped in PR #288** (`perf-gate.yml`, reusable + dispatch), wired as
a new `needs` between conformance and `promote-*` in
`playwright-alpine-browsers.yml`:
- Three arms **in one job on one runner**, real consumer path (`Dockerfile.alpine`
  build-args, real shims/preloads — not a hand-mirrored probe): `candidate`
  (sha just built), `promoted` (current `<browser>-latest`), `official` (PW
  glibc). n=5 interleaved, same pattern as `ff-perf-ab.yml`.
- `assert-perf-gate.py`: per row, hard-fail on `candidate/promoted > 1.00 +
  margin` (ratchet) **and** `candidate/official > 1.00 + margin` (parity);
  geomean ratchet strict ≤1.00, geomean parity ≤1.02. Margins in
  `perf-gate-margins.json`, sized from same-runner A/B noise measured this
  week (tight rows locator_click/int_math/fmod ≈3%, others ≈8%; flat 5% where
  no data yet).
- No `promoted` tag yet (first build of a channel) → ratchet skipped, stated
  in the summary, not a fail.
- Chromium promote split into `pins → perf-gate → promote` stages; the
  main-ref-only guard ([[parked_chromium_promote_and_pgo_comment]] item 2,
  resolved PR #128) moved first in the chain.
- Cost: 3 arms × n=5 ≈ 15 probe shots ≈ 20-25 min per browser, promote path
  only (main), not on PRs.
- Dry-run against real chromium data found 6 real parity breaches (expected —
  campaign is still open) plus a bug (ratchet-vs-self read 1.000 off a
  missing shot instead of INVALID) fixed before shipping.

Companion piece, same conversation: pw-version renovate bumps should only
automerge when the browser revs (CHS_REV/FF_REV/WK_REV) they pull already
have a promoted build that cleared this gate — see
[[project_renovate_pw_lockstep_and_perf_prereq]].

**How to apply:** don't propose loosening chromium's parity gate back to
warn-only without a fresh ruling — this was a deliberate, explicit hardening,
not a default. When the chromium residual-gap campaign
([[project_chromium_residual_gap_candidates]]) lands a row ≤1.00, re-run
`perf-gate-chromium` before assuming promote will go green — it's now a real
blocker, not a report.
