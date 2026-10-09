---
name: project_renovate_pw_lockstep_and_perf_prereq
description: PW version bumps and browser-rev bumps land as separate renovate PRs today, so either can ship alone red; PR #289 groups them, gated on the new perf-gate
metadata:
  type: project
---

Jean ruled (2026-09-21): a Playwright version bump should only be automergeable
by Renovate when the browser builds matching that version exist AND clear the
new above-parity perf gate ([[project_perf_gate_ratchet_and_parity]]).

Gap found: `PW_VERSION` and `CHS_REV`/`FF_REV`/`WK_REV` are bumped by separate
Renovate managers (the Playwright group vs three regex managers fed by
**promoted** ghcr tags). Either PR can land alone — new browser rev with the
old driver, or vice versa — and `test-playwright-browser-versions` only
catches the mismatch after the fact (this is what's red on #234, PW 1.63.0,
open since 09-14).

Fix shipped as **PR #289**: put the three ghcr rev deps into the same Renovate
group as playwright (`packageRules` group, placed after the majors rule so a
rev jump still reads as `loose`-major and keeps `automerge: true`). A tag only
exists once `promote-*` has run, and promote now runs behind the perf gate —
so "matching builds exist at parity" collapses to "the three tags exist,"
which the lockstep group PR can wait on natively.

**Not built yet** (explicit follow-up, not started): nothing today builds the
browsers for a *new* pw version automatically — build chains read
`PW_VERSION` from main's `versions.env`, and promote is main-only. The design
sketch (not implemented): builds + promote dispatched from the
`renovate/playwright` branch, the same way `auto-resolve-aports` already
dispatches builds off aports-ref PRs
([[project_auto_resolve_aports_workflow]]).

**Status 2026-09-21:** #288 and #289 both MERGED. Jean sequenced the
self-building step ("renovate triggering builds of browsers") AFTER chromium
beats parity — the gate hard-fails chromium, so auto-built chs revs would sit
unpromotable until then; build the trigger once chs-latest passes every row.
First gate self-tests failed on `sudo: a password is required` (Dockerfile's
Docker Hub `BASE_IMAGE` default; TP passes the ghcr sha) — fix PR #290 passes
`ghcr.io/jclaveau/alpine-dood-pnpm:edge`.

**How to apply:** if #234 or a future PW-bump PR is still open and someone
asks why, the answer is this lockstep gap, not a renovate config bug — the
self-building trigger is deliberately not built until chromium parity lands;
do not propose it before, do not forget it after.
